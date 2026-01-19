---@class Vibing.Domain.Squad.SquadName
---分隊名の値オブジェクト（不変）
---NATO phonetic alphabetまたはCommanderの制約を強制
local M = {}

---NATO phonetic alphabet定数
---@type string[]
M.NATO_ALPHABET = {
  "Alpha",
  "Bravo",
  "Charlie",
  "Delta",
  "Echo",
  "Foxtrot",
  "Golf",
  "Hotel",
  "India",
  "Juliet",
  "Kilo",
  "Lima",
  "Mike",
  "November",
  "Oscar",
  "Papa",
  "Quebec",
  "Romeo",
  "Sierra",
  "Tango",
  "Uniform",
  "Victor",
  "Whiskey",
  "X-ray",
  "Yankee",
  "Zulu",
}

---Commander固定名
M.COMMANDER = "Commander"

---指定された名前が有効なSquad名かどうか検証
---@param name string 検証する名前
---@return boolean is_valid 有効な場合true
function M.is_valid(name)
  if name == M.COMMANDER then
    return true
  end

  for _, nato_name in ipairs(M.NATO_ALPHABET) do
    if name == nato_name then
      return true
    end
  end

  return false
end

---SquadName値オブジェクトを生成
---@param name string Squad名
---@return table squad_name { value: string }
---@error 無効なSquad名の場合エラー
function M.new(name)
  if not M.is_valid(name) then
    error(string.format("Invalid squad name: %s", name))
  end

  return {
    value = name,
  }
end

---2つのSquadNameが等価かどうか判定
---@param a table SquadName
---@param b table SquadName
---@return boolean is_equal 等価な場合true
function M.equals(a, b)
  return a.value == b.value
end

---Squad名が利用可能な名前のリストから次の未使用名を検索
---@param used_names table<string, boolean> 使用中の名前のセット
---@return string? next_name 次に使用可能な名前（全て使用中の場合nil）
function M.get_next_available(used_names)
  for _, name in ipairs(M.NATO_ALPHABET) do
    if not used_names[name] then
      return name
    end
  end
  return nil
end

return M
