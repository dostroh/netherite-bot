require "rosegold"
require "json"
require "file_utils"

# =============================================================================
# Netherite bot — single-file Rosegold port of netherite_mine.js + netherite_service.js
#
# Writes finds to data/eu.mart3323.jsmacros/persistentVars/debrisFinds.json in
# the same {pos:{x,y,z}, time, mined} shape Mart's JSMacros script uses, so you
# can drop that file into your JSMacros profile and /nt show in-client will
# highlight the debris blocks.
#
# Forward-movement strategy:
#   1. Try move_to. Solid netherrack → done.
#   2. MovementStuck? Mine straight ahead (sweep may have missed a block).
#   3. Still stuck? Assume gap; brute-force place_block_against on candidate
#      anchor blocks until one sticks.
#   4. Try walking again. If still stuck, bail.
#
# Chat commands (gated by MC_COMMANDER env var):
#   !nt stats | show | hide | reset | trim
# =============================================================================

# ---- Config -----------------------------------------------------------------
SERVER         = ENV["MC_SERVER"]?    || "play.civmc.net"
COMMANDER_NAME = ENV["MC_COMMANDER"]?
DATA_DIR       = "data/eu.mart3323.jsmacros/persistentVars"

MINING_HEIGHT   = 120.0
LOW_ANGLE       =  66.5
HIGH_ANGLE      = -85.0
SWEEP_STEPS     = 24
SWEEP_DIG_TICKS = 6
END_Z           = 9000
EAT_THRESHOLD   = 15
SKIPS           = [] of Tuple(Float64, Float64)

DEBRIS_KEY   = "debrisFinds"
DIAMONDS_KEY = "diamonds"

# ---- JSON shapes (matches netherite_service.js exactly) ---------------------
struct Pos
  include JSON::Serializable
  property x : Int32
  property y : Int32
  property z : Int32

  def initialize(@x, @y, @z); end
end

struct Find
  include JSON::Serializable
  property pos : Pos
  property time : Int64
  property mined : Bool

  def initialize(@pos, @time, @mined); end

  def initialize(x : Int32, y : Int32, z : Int32, time : Int64, mined : Bool)
    @pos   = Pos.new(x, y, z)
    @time  = time
    @mined = mined
  end

  def x; pos.x; end
  def y; pos.y; end
  def z; pos.z; end
end

# ---- File-backed store ------------------------------------------------------
FileUtils.mkdir_p(DATA_DIR)

def store_path(name : String) : String
  File.join(DATA_DIR, "#{name}.json")
end

def load_finds(key : String) : Array(Find)
  path = store_path(key)
  return [] of Find unless File.exists?(path)
  Array(Find).from_json(File.read(path))
rescue
  [] of Find
end

def save_finds(key : String, finds : Array(Find))
  File.write(store_path(key), finds.to_json)
rescue ex
  STDERR.puts "[store] write #{key} failed: #{ex.message}"
end

save_finds(DEBRIS_KEY,   [] of Find) unless File.exists?(store_path(DEBRIS_KEY))
save_finds(DIAMONDS_KEY, [] of Find) unless File.exists?(store_path(DIAMONDS_KEY))

# ---- Connect ----------------------------------------------------------------
BOT = Rosegold::Bot.join_game(SERVER)
sleep 3.seconds
puts "[netherite] connected as #{BOT.username} at #{BOT.location}"

module State
  class_property show_hud = false
  class_property last_debris_count = 0
end

# ---- Service: !nt commands + chat-driven find tracking ----------------------
def report(msg : String)
  puts "[nt] #{msg}"
  if cmd = COMMANDER_NAME
    BOT.chat("/msg #{cmd} [nt] #{msg}") rescue nil
  end
end

def bot_block_pos : Tuple(Int32, Int32, Int32)
  b = BOT.location.block # Vec3i, floored
  {b.x, b.y, b.z}
end

def record_find(key : String, xyz : Tuple(Int32, Int32, Int32))
  finds = load_finds(key)
  finds << Find.new(xyz[0], xyz[1], xyz[2], Time.utc.to_unix_ms, false)
  save_finds(key, finds)
  label = key == DEBRIS_KEY ? "debris" : "diamond"
  report("#{label} @ #{xyz[0]} #{xyz[1]} #{xyz[2]}")
end

def collect_debris(loc)
  finds = load_finds(DEBRIS_KEY)
  unmined = finds.select { |f| !f.mined }
  return if unmined.empty?

  loc_v = Rosegold::Vec3d.new(loc.x.to_f64, loc.y.to_f64, loc.z.to_f64)
  candidate = unmined.min_by do |f|
    fv = Rosegold::Vec3d.new(f.x.to_f64, f.y.to_f64, f.z.to_f64)
    fv.dist_sq(loc_v)
  end
  cv = Rosegold::Vec3d.new(candidate.x.to_f64, candidate.y.to_f64, candidate.z.to_f64)
  return if cv.dist_sq(loc_v) > 100.0 # 10 blocks

  updated = finds.map do |f|
    if !f.mined && f.x == candidate.x && f.y == candidate.y && f.z == candidate.z
      Find.new(f.x, f.y, f.z, f.time, true)
    else
      f
    end
  end
  save_finds(DEBRIS_KEY, updated)
end

def dispatch_command(verb)
  case verb
  when "show"
    State.show_hud = true
    finds = load_finds(DEBRIS_KEY).reject(&.mined)
    report("showing #{finds.size} unmined debris find(s):")
    finds.each { |f| report("  #{f.x} #{f.y} #{f.z}") }
  when "hide", "clearhud"
    State.show_hud = false
    report("show-mode off")
  when "stats"
    finds = load_finds(DEBRIS_KEY)
    if finds.empty?
      report("no debris finds recorded yet")
    else
      oldest        = finds.min_by(&.time)
      mined_count   = finds.count(&.mined)
      unmined_count = finds.size - mined_count
      session_ms    = (Time.utc.to_unix_ms - oldest.time).to_f
      minutes       = session_ms / 60_000.0
      per_hour      = finds.size / (session_ms / 3_600_000.0)
      report("session: #{"%.2f" % minutes} min")
      report("debris found: #{finds.size} (#{unmined_count} not yet mined)")
      report("debris/hour: #{"%.2f" % per_hour}")
    end
  when "reset"
    save_finds(DEBRIS_KEY, [] of Find)
    report("debris finds reset")
  when "trim"
    finds = load_finds(DEBRIS_KEY).reject(&.mined)
    save_finds(DEBRIS_KEY, finds)
    report("trimmed; #{finds.size} unmined finds remain")
  end
end

# ---- TextComponent → plain string (recursive, strips color codes) -----------
# SystemChatMessage#message is a TextComponent; its #to_s returns the object
# address, not the text. We have to walk text + extra (child components) ourselves.
def flatten_text(comp) : String
  return "" unless comp
  String.build do |io|
    io << comp.text if comp.text
    comp.extra.try &.each { |child| io << flatten_text(child) }
  end
end


BOT.on(Rosegold::Clientbound::SystemChatMessage) do |event|
  msg = flatten_text(event.message).strip

  if msg.starts_with?("You sense a diamond")
    record_find(DIAMONDS_KEY, bot_block_pos)
  elsif msg.starts_with?("You sense debris")
    record_find(DEBRIS_KEY, bot_block_pos)
  end

  if m = msg.match(/!nt\s+(\w+)/)
    dispatch_command(m[1])
  end
end

BOT.on(Rosegold::Clientbound::PlayerChatMessage) do |event|
  sender = flatten_text(event.network_name)
  msg    = event.message # already a String on PlayerChatMessage
  allowed = COMMANDER_NAME.nil? || sender == COMMANDER_NAME || sender == BOT.username
  next unless allowed
  next unless msg.starts_with?("!nt ")
  verb = msg[4..].strip.split(/\s+/).first?
  dispatch_command(verb) if verb
end

# ---- Inventory maintenance --------------------------------------------------
def valid_pickaxe?(slot) : Bool
  return false unless slot.name == "diamond_pickaxe"
  return false unless slot.durability > 10
  # JS condition: efficiency > 1 && efficiency < 4 (so Eff II or III).
  eff = slot.efficiency rescue 0
  eff > 1 && eff < 4
end

def maintain_pickaxe!
  return if valid_pickaxe?(BOT.main_hand)
  ok = BOT.inventory.pick { |s| valid_pickaxe?(s) }
  unless ok
    BOT.chat("/g ! out of pickaxes, disconnecting")
    BOT.wait_ticks 5
    raise "out of pickaxes"
  end
end

def ensure_netherrack!
  return if BOT.main_hand.name == "netherrack"
  ok = BOT.inventory.pick("netherrack")
  unless ok
    BOT.chat("/g ! out of netherrack")
    raise "out of netherrack"
  end
end

def maintain_hunger!
  return if BOT.food > EAT_THRESHOLD
  BOT.eat! rescue puts "[miner] eat! failed (out of food?)"
end

# ---- Misc helpers -----------------------------------------------------------
def lerp(a : Float64, b : Float64, t : Float64) : Float64
  a + t * (b - a)
end

def in_skip_zone? : Bool
  z = BOT.location.z
  SKIPS.any? { |range| z >= range[0] && z <= range[1] }
end

def check_debris_pickup
  now = BOT.inventory.count("ancient_debris")
  if now > State.last_debris_count
    collect_debris(BOT.location)
  end
  State.last_debris_count = now
end

# ---- Mining steps -----------------------------------------------------------
def center_on_block
  loc = BOT.location
  centered = loc.block.centered_3d.with_y(loc.y) # x+0.5, y, z+0.5
  return if loc.almost_eq(centered, closer_than: 0.1)
  BOT.move_to(centered) rescue nil
  BOT.wait_ticks 4
end

def pillar_up
  while BOT.location.y < MINING_HEIGHT
    ensure_netherrack!
    BOT.pitch = 90.0
    BOT.wait_ticks 1

    feet_blk = BOT.location.block.down(1) # block directly under feet
    begin
      BOT.start_jump
      BOT.wait_ticks 2
      BOT.place_block_against(feet_blk, :top)
    rescue ex
      puts "[miner] pillar place failed: #{ex.message}"
    end
    BOT.land_on_ground(timeout_ticks: 20) rescue nil
    break if BOT.location.y >= MINING_HEIGHT
  end
end

# Sweep one side of the ring by panning pitch low→high while attacking.
def pitched_sweep(direction_face : Symbol)
  yaw_at_start = BOT.yaw
  SWEEP_STEPS.times do |i|
    alpha = i.to_f64 / SWEEP_STEPS
    pitch = lerp(LOW_ANGLE, HIGH_ANGLE, alpha)

    # Aim eyes in the given cardinal direction at the current pitch.
    # Pick a Vec3d 5 blocks away in that direction.
    eye = Rosegold::Vec3d.new(BOT.location.x, BOT.location.y + 1.62, BOT.location.z)
    target = case direction_face
             when :east  then eye.east(5)
             when :west  then eye.west(5)
             when :north then eye.north(5)
             when :south then eye.south(5)
             else             eye.east(5)
             end
    BOT.look_at(target)
    BOT.yaw   = yaw_at_start
    BOT.pitch = pitch
    BOT.dig(SWEEP_DIG_TICKS)
  end
end

def sweep_ring
  maintain_pickaxe!
  pitched_sweep(:east)
  maintain_pickaxe!
  pitched_sweep(:west)
end

def mine_ahead
  maintain_pickaxe!
  eye   = Rosegold::Vec3d.new(BOT.location.x, BOT.location.y + 1.62, BOT.location.z)
  ahead = eye.south(5) # +Z = south in MC
  BOT.look_at(ahead)
  BOT.pitch = 0.0
  BOT.dig(20)
  BOT.pitch = 30.0
  BOT.dig(20)
end

def try_blind_bridge
  ensure_netherrack!
  BOT.sneak
  BOT.wait_ticks 2

  feet = BOT.location.block # Vec3i

  # Candidate (anchor Vec3i, face) pairs. Try the most obvious ones first.
  candidates = [
    {feet.down(1),                :top},   # block directly beneath
    {feet.down(1).north(1),       :top},   # block behind+down (we came from -Z)
    {feet.down(1).north(1),       :south}, # south face of behind-down
    {feet.down(1).east(1),        :west},  # west face of east-down
    {feet.down(1).west(1),        :east},  # east face of west-down
    {feet.north(1),               :south}, # block behind at foot level, south face
  ]

  placed = false
  candidates.each do |(anchor, face)|
    begin
      BOT.place_block_against(anchor, face)
      placed = true
      BOT.wait_ticks 2
      break
    rescue
      # try the next candidate
    end
  end
  BOT.unsneak
  placed
end

def step_forward
  start_z = BOT.location.z
  target  = BOT.location.with_z(start_z + 1.0)

  begin
    BOT.move_to(target)
    return true
  rescue Rosegold::Physics::MovementStuck
    puts "[miner] stuck moving forward; trying mine_ahead"
  end

  mine_ahead
  begin
    BOT.move_to(target)
    return true
  rescue Rosegold::Physics::MovementStuck
    puts "[miner] still stuck; trying blind bridge"
  end

  bridged = try_blind_bridge
  unless bridged
    puts "[miner] couldn't bridge — no candidate anchor worked"
    return false
  end

  begin
    BOT.move_to(target)
    return true
  rescue Rosegold::Physics::MovementStuck
    puts "[miner] still stuck after bridging; giving up"
    return false
  end
end

# ---- Main loop --------------------------------------------------------------
puts "[netherite] starting miner loop; commander=#{COMMANDER_NAME || "(self)"}"

begin
  while BOT.connected?
    center_on_block
    pillar_up
    sweep_ring unless in_skip_zone?

    unless step_forward
      report("stuck — disconnecting for manual intervention")
      break
    end

    maintain_pickaxe!
    maintain_hunger!
    check_debris_pickup

    break if BOT.location.z >= END_Z
  end
rescue ex
  puts "[miner] stopped: #{ex.message}"
  ex.backtrace.try &.each { |line| puts "  #{line}" }
ensure
  BOT.chat("[netherite] disconnecting") rescue nil
  sleep 1.second
  BOT.disconnect rescue nil
end
