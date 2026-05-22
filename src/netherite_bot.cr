require "rosegold"
require "json"
require "file_utils"

# =============================================================================
# Netherite bot — single-file Rosegold port of netherite_mine.js + netherite_service.js
#
# Caveats vs the JS originals (Rosegold is headless, so some things change):
#   * Sweep mining uses per-pitch-step `bot.dig` instead of "hold attack while
#     panning the camera". Tune SWEEP_STEPS / SWEEP_DIG_TICKS.
#   * No HUD / Draw3D. `!nt show` DMs you the coordinates of unmined debris.
#   * No client command manager. Commands are `!nt stats / show / hide / reset / trim`
#     sent in chat by MC_COMMANDER (env var) or by the bot itself.
#   * No ItemPickup event. We poll `inventory.count("ancient_debris")` deltas.
#   * Hover-text "Location: x y z" scrape is best-effort; falls back to bot's
#     current block pos (same fallback the JS has for debris).
# =============================================================================

# ---- Config -----------------------------------------------------------------
SERVER          = ENV["MC_SERVER"]?    || "play.civmc.net"
COMMANDER       = ENV["MC_COMMANDER"]? # in-game name allowed to drive !nt commands; nil = self-only
DATA_DIR        = "data/eu.mart3323.jsmacros/persistentVars"

MINING_HEIGHT        = 120.0
LOW_ANGLE            =  66.5_f32
HIGH_ANGLE           = -85.0_f32
SWEEP_STEPS          = 24            # pitch steps per side
SWEEP_DIG_TICKS      = 6             # ticks of dig per pitched step
SKIPS                = [] of Tuple(Float64, Float64)
END_Z                = 9000
EAT_THRESHOLD        = 15

WALK_DIR  = Rosegold::Vec3d.new(0.0, 0.0, 1.0)
CROSS_DIR = Rosegold::Vec3d.new(WALK_DIR.z, 0.0, -WALK_DIR.x)

DEBRIS_KEY   = "debrisFinds"
DIAMONDS_KEY = "diamonds"

# ---- Persistent store (one JSON file per key, mirrors Mart's Proxy) ---------
FileUtils.mkdir_p(DATA_DIR)

def store_path(name : String) : String
  File.join(DATA_DIR, "#{name}.json")
end

def store_get_array(name : String) : Array(JSON::Any)
  path = store_path(name)
  return [] of JSON::Any unless File.exists?(path)
  (JSON.parse(File.read(path)).as_a? || [] of JSON::Any)
rescue JSON::ParseException
  [] of JSON::Any
end

def store_set(name : String, value)
  File.write(store_path(name), value.to_json)
rescue ex
  STDERR.puts "[store] write #{name} failed: #{ex.message}"
end

struct Pos
  include JSON::Serializable
  property x : Int32, y : Int32, z : Int32

  def initialize(@x, @y, @z); end
end

struct Find
  include JSON::Serializable
  property pos : Pos
  property time : Int64
  property mined : Bool

  def initialize(@pos, @time, @mined); end

  # Convenience for the old `Find.new(x, y, z, time, mined)` callsites.
  def self.new(x : Int32, y : Int32, z : Int32, time : Int64, mined : Bool) : self
    new(Pos.new(x, y, z), time, mined)
  end

  # And convenience accessors so existing code reading f.x still works.
  def x; pos.x; end
  def y; pos.y; end
  def z; pos.z; end
end

def load_finds(key : String) : Array(Find)
  store_get_array(key).map { |any| Find.from_json(any.to_json) }
end

def save_finds(key : String, finds : Array(Find))
  store_set(key, finds)
end

# Seed empty arrays on first run.
store_set(DEBRIS_KEY,   [] of Find) unless File.exists?(store_path(DEBRIS_KEY))
store_set(DIAMONDS_KEY, [] of Find) unless File.exists?(store_path(DIAMONDS_KEY))

# ---- Connect ----------------------------------------------------------------
bot = Rosegold::Bot.join_game(SERVER)
sleep 3.seconds
puts "[netherite] connected as #{bot.username} at #{bot.feet}"

# ---- Service: chat-driven find tracking + !nt commands ----------------------
show_hud = false
last_debris_count = 0

report = ->(msg : String) do
  puts "[nt] #{msg}"
  if cmd = COMMANDER
    bot.chat "/msg #{cmd} [nt] #{msg}" rescue nil
  end
end

bot_block_pos = -> do
  pos = bot.feet
  {pos.x.floor.to_i, pos.y.floor.to_i, pos.z.floor.to_i}
end

record_find = ->(key : String, xyz : Tuple(Int32, Int32, Int32)) do
  finds = load_finds(key)
  finds << Find.new(xyz[0], xyz[1], xyz[2], Time.utc.to_unix_ms, false)
  save_finds(key, finds)
  label = key == DEBRIS_KEY ? "debris" : "diamond"
  report.call("#{label} @ #{xyz[0]} #{xyz[1]} #{xyz[2]}")
end

collect_debris = ->(pos : Rosegold::Vec3d) do
  finds = load_finds(DEBRIS_KEY)
  candidate = finds.select { |f| !f.mined }.min_by? do |f|
    dx = f.x - pos.x; dy = f.y - pos.y; dz = f.z - pos.z
    dx*dx + dy*dy + dz*dz
  end
  next unless candidate
  dx = candidate.x - pos.x; dy = candidate.y - pos.y; dz = candidate.z - pos.z
  next if dx*dx + dy*dy + dz*dz > 100.0 # 10 blocks

  updated = finds.map do |f|
    if !f.mined && f.x == candidate.x && f.y == candidate.y && f.z == candidate.z
      Find.new(f.x, f.y, f.z, f.time, true)
    else
      f
    end
  end
  save_finds(DEBRIS_KEY, updated)
end

dispatch = ->(verb : String?) do
  case verb
  when "show"
    show_hud = true
    finds = load_finds(DEBRIS_KEY).reject(&.mined)
    report.call("showing #{finds.size} unmined debris find(s):")
    finds.each { |f| report.call("  #{f.x} #{f.y} #{f.z}") }
  when "hide", "clearhud"
    show_hud = false
    report.call("hud-equivalent hidden")
  when "stats"
    finds = load_finds(DEBRIS_KEY)
    if finds.empty?
      report.call("no debris finds recorded yet")
    else
      oldest = finds.min_by(&.time)
      mined_count   = finds.count(&.mined)
      unmined_count = finds.size - mined_count
      session_ms    = (Time.utc.to_unix_ms - oldest.time).to_f
      minutes       = session_ms / 60_000.0
      per_hour      = finds.size / (session_ms / 3_600_000.0)
      report.call("session: #{"%.2f" % minutes} min")
      report.call("debris found: #{finds.size} (#{unmined_count} not yet mined)")
      report.call("debris/hour: #{"%.2f" % per_hour}")
    end
  when "reset"
    save_finds(DEBRIS_KEY, [] of Find)
    report.call("debris finds reset")
  when "trim"
    finds = load_finds(DEBRIS_KEY).reject(&.mined)
    save_finds(DEBRIS_KEY, finds)
    report.call("trimmed; #{finds.size} unmined finds remain")
  end
end

# System chat: server messages ("You sense debris/diamond") + self-driven commands.
bot.on(Rosegold::Clientbound::SystemChatMessage) do |event|
  msg = event.message.to_s.strip
  if msg.starts_with?("You sense a diamond")
    record_find.call(DIAMONDS_KEY, bot_block_pos.call)
  elsif msg.starts_with?("You sense debris")
    record_find.call(DEBRIS_KEY, bot_block_pos.call)
  end
  if m = msg.match(/!nt\s+(\w+)/)
    dispatch.call(m[1])
  end
end

# Player chat: commands from MC_COMMANDER (or bot itself).
bot.on(Rosegold::Clientbound::PlayerChatMessage) do |event|
  sender = event.network_name.to_s
  msg    = event.message.to_s
  allowed = COMMANDER.nil? || sender == COMMANDER || sender == bot.username
  next unless allowed
  next unless msg.starts_with?("!nt ")
  verb = msg[4..].strip.split(/\s+/).first?
  dispatch.call(verb)
end

# ---- Miner helpers ----------------------------------------------------------
lerp = ->(a : Float32, b : Float32, t : Float32) { a + t * (b - a) }

look_direction = ->(dir : Rosegold::Vec3d) do
  eye    = bot.feet + Rosegold::Vec3d.new(0.0, bot.eye_height, 0.0)
  target = eye + dir
  bot.look_at(target)
end

in_skip_zone? = -> do
  z = bot.feet.z
  SKIPS.any? { |(lo, hi)| z >= lo && z <= hi }
end

block_below_feet = -> do
  f = bot.feet
  Rosegold::Vec3i.new(f.x.floor.to_i, (f.y - 1).floor.to_i, f.z.floor.to_i)
end

# JS pickaxe condition: diamond, durability > 10, eff > 1 && eff < 4 (so II or III).
valid_pickaxe? = ->(slot : Rosegold::Slot) do
  next false unless slot.name == "diamond_pickaxe"
  next false unless slot.durability > 10
  enchants = slot.enchantments rescue nil
  next false unless enchants
  lvl = enchants["efficiency"]?
  next false unless lvl
  lvl > 1 && lvl < 4
end

maintain_pickaxe! = -> do
  next if valid_pickaxe?.call(bot.main_hand)
  begin
    bot.inventory.pick! { |s| valid_pickaxe?.call(s) }
  rescue Rosegold::Inventory::ItemNotFoundError
    bot.chat "/g ! out of pickaxes, disconnecting"
    bot.wait_ticks 5
    raise "out of pickaxes"
  end
end

ensure_netherrack! = -> do
  next if bot.main_hand.name == "netherrack"
  begin
    bot.inventory.pick! "netherrack"
  rescue Rosegold::Inventory::ItemNotFoundError
    bot.chat "/g ! out of netherrack"
    raise "out of netherrack"
  end
end

maintain_hunger! = -> do
  next if bot.food > EAT_THRESHOLD
  bot.eat! rescue puts "[miner] eat! failed (out of food?)"
end

check_debris_pickup = -> do
  now = bot.inventory.count("ancient_debris")
  if now > last_debris_count
    collect_debris.call(bot.feet)
  end
  last_debris_count = now
end

# ---- Miner steps ------------------------------------------------------------
center_on_block = -> do
  feet = bot.feet
  bx = feet.x.floor
  bz = feet.z.floor
  if (feet.x - (bx + 0.5)).abs > 0.1 || (feet.z - (bz + 0.5)).abs > 0.1
    bot.move_to(bx + 0.5, feet.y, bz + 0.5)
    bot.wait_ticks 4
  end
end

pillar_up = -> do
  while bot.feet.y < MINING_HEIGHT
    ensure_netherrack!.call
    bot.pitch = 90.0_f32
    bot.wait_ticks 1
    feet_block = block_below_feet.call
    bot.start_jumping
    bot.wait_ticks 2
    begin
      bot.place_block_against(feet_block, :top)
    rescue ex
      puts "[miner] pillar place failed (#{ex.message}); retrying"
    end
    bot.stop_jumping
    bot.wait_ticks 2
    break if bot.feet.y >= MINING_HEIGHT
  end
end

pitched_sweep = -> do
  yaw = bot.yaw
  SWEEP_STEPS.times do |i|
    alpha = i.to_f32 / SWEEP_STEPS
    bot.yaw   = yaw
    bot.pitch = lerp.call(LOW_ANGLE, HIGH_ANGLE, alpha)
    bot.dig(SWEEP_DIG_TICKS)
  end
end

sweep_ring = -> do
  maintain_pickaxe!.call
  look_direction.call(CROSS_DIR)
  pitched_sweep.call
  maintain_pickaxe!.call
  look_direction.call(CROSS_DIR.scale(-1.0))
  pitched_sweep.call
end

bridge_if_gap = ->(dest : Rosegold::Vec3d) do
  below = Rosegold::Vec3i.new(dest.x.floor.to_i, (dest.y - 1).floor.to_i, dest.z.floor.to_i)
  block = bot.dimension.block_at(below) rescue nil
  next if block && block.name != "air" && block.name != "cave_air"

  ensure_netherrack!.call
  bot.sneak
  behind = Rosegold::Vec3i.new(bot.feet.x.floor.to_i, (bot.feet.y - 1).floor.to_i, bot.feet.z.floor.to_i)
  begin
    bot.place_block_against(behind, :north)
  rescue ex
    puts "[miner] bridge failed: #{ex.message}"
  end
  bot.stop_sneaking
end

mine_ahead = -> do
  bot.pitch = 12.5_f32
  bot.dig(40)
end

tunnel_forward = -> do
  start  = bot.feet
  target = Rosegold::Vec3d.new(start.x, start.y, start.z + 1.0)
  bridge_if_gap.call(target)
  begin
    bot.move_to(target.x, target.z)
  rescue Rosegold::Physics::MovementStuck
    mine_ahead.call
    bot.move_to(target.x, target.z)
  end
end

# ---- Main loop --------------------------------------------------------------
puts "[netherite] starting miner loop; commander=#{COMMANDER || "(self)"}"

begin
  while bot.connected?
    center_on_block.call
    pillar_up.call
    sweep_ring.call unless in_skip_zone?.call
    tunnel_forward.call
    maintain_pickaxe!.call
    maintain_hunger!.call
    check_debris_pickup.call
    break if bot.feet.z >= END_Z
  end
rescue ex : Rosegold::Physics::MovementStuck
  puts "[miner] movement stuck: #{ex.message}; bailing"
rescue ex
  puts "[miner] stopped: #{ex.message}"
  ex.backtrace.try &.each { |line| puts "  #{line}" }
ensure
  bot.chat "[netherite] disconnecting" rescue nil
  sleep 1.second
  bot.disconnect rescue nil
end
