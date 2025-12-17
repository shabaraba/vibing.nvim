# Contributing to vibing.nvim

Thank you for considering contributing to vibing.nvim! This document provides guidelines and instructions for contributing.

## 🚀 Getting Started

### Prerequisites

- Neovim >= 0.8.0
- Node.js >= 16.0.0
- npm or yarn
- Git
- `luac` for Lua syntax checking

### Development Setup

1. **Fork and clone the repository**

```bash
git clone https://github.com/YOUR_USERNAME/vibing.nvim.git
cd vibing.nvim
```

2. **Install dependencies**

```bash
npm install
```

3. **Verify installation**

```bash
npm run validate
```

4. **Test the plugin in Neovim**

Add to your Neovim config:

```lua
{
  dir = "~/path/to/vibing.nvim",
  config = function()
    require("vibing").setup()
  end,
}
```

## 📝 Development Workflow

### Making Changes

1. **Create a feature branch**

```bash
git checkout -b feature/your-feature-name
# or
git checkout -b fix/your-bug-fix
```

2. **Make your changes**

- Write clean, readable code
- Follow existing code style
- Add comments for complex logic
- Update documentation if needed

3. **Test your changes**

```bash
# Validate Lua syntax
npm run check

# Test the wrapper
npm test

# Run all checks
npm run validate
```

4. **Commit your changes**

Use [Conventional Commits](https://www.conventionalcommits.org/) format:

```bash
git commit -m "feat: add new feature"
git commit -m "fix: resolve bug in chat buffer"
git commit -m "docs: update README examples"
```

**Commit types:**

- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `style`: Code formatting (no logic change)
- `refactor`: Code refactoring
- `test`: Adding or updating tests
- `chore`: Maintenance tasks

5. **Push and create Pull Request**

```bash
git push -u origin feature/your-feature-name
```

Then create a PR on GitHub.

## 🎨 Code Style

### Lua

- Use 2 spaces for indentation
- Use snake_case for variables and functions
- Use PascalCase for classes/modules
- Add type annotations with `---@` comments
- Keep functions focused and small
- Avoid deep nesting (max 3-4 levels)

**Example:**

```lua
---@param config Vibing.Config
---@return boolean success
local function validate_config(config)
  if not config.adapter then
    return false
  end
  return true
end
```

### JavaScript/Node.js

- Use ES modules (`import`/`export`)
- Use camelCase for variables and functions
- Use async/await for asynchronous code
- Handle errors properly

## 📋 Pull Request Guidelines

### Before Submitting

- [ ] Code follows project style
- [ ] All tests pass (`npm run validate`)
- [ ] Documentation updated if needed
- [ ] Commit messages follow convention
- [ ] No unrelated changes included

### PR Description

Include:

- **What**: Brief description of changes
- **Why**: Reason for the change
- **How**: Implementation approach (if complex)
- **Testing**: How you tested the changes
- **Related Issues**: Link to related issues

**Example:**

```markdown
## What

Add support for custom slash commands

## Why

Users requested ability to define their own chat commands

## How

- Created command registry in chat/commands.lua
- Added register() and execute() functions
- Updated documentation

## Testing

- Tested with custom /greet command
- Verified existing commands still work
- Ran npm run validate

fixes #42
```

## 🐛 Bug Reports

When reporting bugs, include:

1. **Description**: Clear description of the issue
2. **Steps to Reproduce**: Minimal steps to reproduce
3. **Expected Behavior**: What should happen
4. **Actual Behavior**: What actually happens
5. **Environment**:
   - Neovim version: `nvim --version`
   - OS: macOS/Linux/Windows
   - Plugin version/commit
6. **Logs**: Relevant error messages or logs

## 💡 Feature Requests

When requesting features:

1. **Use Case**: Describe the problem you're trying to solve
2. **Proposed Solution**: Your idea for solving it
3. **Alternatives**: Other solutions you've considered
4. **Additional Context**: Screenshots, examples, etc.

## 🧪 Testing

### Manual Testing

Test your changes thoroughly:

1. **Chat functionality**
   - Open/close chat window
   - Send messages
   - Add/clear context
   - Slash commands

2. **Inline actions**
   - Test each action (fix, feat, explain, etc.)
   - Test custom instructions
   - Test with various code selections

3. **Configuration**
   - Test with different config options
   - Test permissions
   - Test window positions

### Automated Testing

Currently, we have basic checks:

```bash
npm test        # Basic wrapper test
npm run check   # Lua syntax validation
```

## 📚 Documentation

Update documentation when:

- Adding new features
- Changing configuration options
- Modifying commands
- Changing behavior

Files to update:

- `README.md` - User-facing documentation
- `doc/vibing.txt` - Vim help file
- `CLAUDE.md` - Architecture documentation (if needed)

## 🤝 Code Review

All contributions go through code review. Reviewers will check:

- Code quality and style
- Functionality and correctness
- Documentation completeness
- Test coverage
- Breaking changes

Be open to feedback and questions!

## 📞 Getting Help

- **Issues**: Open an issue for bugs or features
- **Discussions**: Use GitHub Discussions for questions
- **Documentation**: Check README.md and doc/vibing.txt

## 📜 License

By contributing, you agree that your contributions will be licensed under the MIT License.

---

Thank you for contributing to vibing.nvim! 🎉
