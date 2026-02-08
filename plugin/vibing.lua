-- vibing.nvim auto-detection for chat files

---@diagnostic disable-next-line: undefined-global
local vim = vim

-- chat_detect.lua モジュールを使用してチャットバッファを自動検知
local ChatDetect = require("vibing.infrastructure.storage.chat_detect")
ChatDetect.setup()
