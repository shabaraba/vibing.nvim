--- Test seam for the model catalogue.
---
--- `ModelCatalog.candidates_for` asks a backend's CLI which models it has, so on a machine that
--- actually has codex or grok installed a spec asserting the fallback lists races a real answer
--- landing mid-file. Reporting "no CLI is installed" makes those specs assert what they mean.
---
--- Shared rather than written per spec file: the catalogue decides whether to probe on more than
--- one condition, and a second condition added later must not need three spec files edited.
--- @module tests.helpers.model_catalog

local ModelCatalog = require("vibing.infrastructure.adapter.models.catalog")

local M = {}

--- Report every CLI as missing and drop whatever was already discovered.
--- @return fun() restore pair this with `after_each`
function M.without_clis()
  local original_executable = vim.fn.executable
  vim.fn.executable = function()
    return 0
  end
  ModelCatalog.clear_cache()

  return function()
    vim.fn.executable = original_executable
    ModelCatalog.clear_cache()
  end
end

return M
