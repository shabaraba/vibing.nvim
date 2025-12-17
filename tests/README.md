# vibing.nvim Tests

This directory contains automated tests for vibing.nvim.

## Requirements

- Neovim >= 0.8.0
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) - Testing framework

## Installation

Install plenary.nvim with your package manager:

### Using lazy.nvim

```lua
{
  "nvim-lua/plenary.nvim",
  lazy = false,
}
```

### Using packer.nvim

```lua
use "nvim-lua/plenary.nvim"
```

## Running Tests

### All Tests

```bash
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"
```

### Single Test File

```bash
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/config_spec.lua"
```

### Via npm

```bash
npm run test:lua
```

## Test Structure

```
tests/
├── minimal_init.lua    # Minimal Neovim setup for tests
├── config_spec.lua     # Tests for config module
└── README.md          # This file
```

## Writing Tests

Tests use plenary.nvim's busted-style API:

```lua
describe("module_name", function()
  before_each(function()
    -- Setup before each test
  end)

  it("should do something", function()
    assert.equals(expected, actual)
  end)
end)
```

### Available Assertions

- `assert.equals(expected, actual)`
- `assert.is_true(value)`
- `assert.is_false(value)`
- `assert.is_nil(value)`
- `assert.is_not_nil(value)`
- `assert.is_table(value)`
- `assert.has_no.errors(function)`

## Coverage Goals

- Core modules: config, init
- Adapters: agent_sdk, claude
- Context system
- UI components
- Utility functions

Target: >50% code coverage

## CI Integration

Tests run automatically on every push and pull request via GitHub Actions.

## Contributing

When adding new features:

1. Write tests first (TDD)
2. Ensure all tests pass
3. Maintain or improve coverage
4. Update this README if needed

## Troubleshooting

### plenary.nvim not found

Ensure plenary.nvim is installed and in your runtimepath:

```bash
nvim --headless -c "lua print(vim.inspect(vim.api.nvim_list_runtime_paths()))" -c "quit"
```

### Tests fail to run

Check Neovim version:

```bash
nvim --version
```

Must be >= 0.8.0

## Resources

- [plenary.nvim Documentation](https://github.com/nvim-lua/plenary.nvim)
- [busted Testing Framework](https://olivinelabs.com/busted/)
- [Neovim Lua Guide](https://neovim.io/doc/user/lua-guide.html)
