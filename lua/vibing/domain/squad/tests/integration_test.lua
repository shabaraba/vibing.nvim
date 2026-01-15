---@diagnostic disable: lowercase-global
---Squad Naming System統合テスト
---各レイヤーの動作を検証

local SquadName = require("vibing.domain.squad.value_objects.squad_name")
local SquadRole = require("vibing.domain.squad.value_objects.squad_role")
local Entity = require("vibing.domain.squad.entity")
local NamingService = require("vibing.domain.squad.services.naming_service")
local Registry = require("vibing.infrastructure.squad.registry")

---テスト結果をカウント
local tests_passed = 0
local tests_failed = 0

---テストアサーション
local function assert_equal(actual, expected, msg)
  if actual == expected then
    tests_passed = tests_passed + 1
    print(string.format("✓ %s", msg or "Test passed"))
  else
    tests_failed = tests_failed + 1
    print(string.format("✗ %s (expected: %s, got: %s)", msg or "Test failed", expected, actual))
  end
end

local function assert_true(value, msg)
  if value then
    tests_passed = tests_passed + 1
    print(string.format("✓ %s", msg or "Test passed"))
  else
    tests_failed = tests_failed + 1
    print(string.format("✗ %s (expected true)", msg or "Test failed"))
  end
end

local function assert_false(value, msg)
  if not value then
    tests_passed = tests_passed + 1
    print(string.format("✓ %s", msg or "Test passed"))
  else
    tests_failed = tests_failed + 1
    print(string.format("✗ %s (expected false)", msg or "Test failed"))
  end
end

---テスト: SquadName の検証
print("\n=== SquadName Tests ===")

local valid_name = SquadName.new("Alpha")
assert_equal(valid_name.value, "Alpha", "Valid NATO name created")

local commander_name = SquadName.new("Commander")
assert_equal(commander_name.value, "Commander", "Commander name created")

assert_true(SquadName.is_valid("Alpha"), "Alpha is valid")
assert_true(SquadName.is_valid("Zulu"), "Zulu is valid")
assert_true(SquadName.is_valid("Commander"), "Commander is valid")
assert_false(SquadName.is_valid("Invalid"), "Invalid name rejected")

---テスト: SquadRole の検証
print("\n=== SquadRole Tests ===")

local commander_role = SquadRole.new(SquadRole.COMMANDER)
assert_equal(commander_role.value, SquadRole.COMMANDER, "Commander role created")

local squad_role = SquadRole.new(SquadRole.SQUAD)
assert_equal(squad_role.value, SquadRole.SQUAD, "Squad role created")

---テスト: Squad Entity
print("\n=== Squad Entity Tests ===")

local squad = Entity.new({
  name = "Alpha",
  role = SquadRole.SQUAD,
  bufnr = 1,
  task_ref = "task-123",
})

assert_equal(squad.name.value, "Alpha", "Squad name set correctly")
assert_equal(squad.role.value, SquadRole.SQUAD, "Squad role set correctly")
assert_equal(squad.bufnr, 1, "Squad bufnr set correctly")
assert_equal(squad.task_ref, "task-123", "Squad task_ref set correctly")

---テスト: Frontmatter変換
print("\n=== Frontmatter Conversion Tests ===")

local frontmatter = Entity.to_frontmatter(squad)
assert_equal(frontmatter.squad_name, "Alpha", "Frontmatter squad_name correct")
assert_equal(frontmatter.task_type, SquadRole.SQUAD, "Frontmatter task_type correct")

local restored = Entity.from_frontmatter(frontmatter, 1)
assert_equal(restored.name.value, "Alpha", "Restored squad name correct")

---テスト: Registry
print("\n=== Registry Tests ===")

Registry.clear_all()

Registry.register("Alpha", 1)
assert_false(Registry.is_available("Alpha"), "Alpha marked as used after registration")
assert_true(Registry.is_available("Bravo"), "Bravo is available")

Registry.register("Bravo", 2)
local active = Registry.get_all_active()
assert_equal(active["Alpha"], 1, "Alpha registered in registry")
assert_equal(active["Bravo"], 2, "Bravo registered in registry")

Registry.unregister(1)
active = Registry.get_all_active()
assert_true(active["Alpha"] == nil, "Alpha unregistered from registry")
assert_equal(active["Bravo"], 2, "Bravo still registered")

Registry.clear_all()

---テスト: NamingService
print("\n=== NamingService Tests ===")

local context = {
  cwd = vim.fn.getcwd(),
  bufnr = 100,
  task_ref = nil,
}

local assigned_squad = NamingService.assign_squad_name(context, Registry)
assert_equal(assigned_squad.name.value, "Alpha", "First squad named Alpha")

Registry.register(assigned_squad.name.value, assigned_squad.bufnr)

-- 次の割り当ては Bravo になるはず
context.bufnr = 101
assigned_squad = NamingService.assign_squad_name(context, Registry)
assert_equal(assigned_squad.name.value, "Bravo", "Second squad named Bravo")

Registry.clear_all()

---テスト: NATO名の全26個の順序
print("\n=== NATO Alphabet Tests ===")

assert_equal(#SquadName.NATO_ALPHABET, 26, "NATO alphabet has 26 names")
assert_equal(SquadName.NATO_ALPHABET[1], "Alpha", "First is Alpha")
assert_equal(SquadName.NATO_ALPHABET[26], "Zulu", "Last is Zulu")

---結果表示
print(string.format("\n=== Test Results ==="))
print(string.format("Passed: %d", tests_passed))
print(string.format("Failed: %d", tests_failed))
print(string.format("Total: %d", tests_passed + tests_failed))

if tests_failed == 0 then
  print("✓ All tests passed!")
else
  print(string.format("✗ %d test(s) failed", tests_failed))
end
