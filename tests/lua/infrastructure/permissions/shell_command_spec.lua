local shell_command = require("vibing.infrastructure.permissions.shell_command")
local job_command = require("vibing.infrastructure.permissions.job_command")
local matchers = require("vibing.infrastructure.permissions.matchers")

describe("shell_command.from_ex", function()
  it("extracts the command line of a literal shell form", function()
    for command, expected in pairs({
      [":!ls -la"] = "ls -la",
      ["silent !ls"] = "ls",
      [":%!sort"] = "sort",
      ["0r !ls"] = "ls",
      ["w! !cmd"] = "cmd",
      ["write ++ff=unix !wc"] = "wc",
      ["terminal npm run dev"] = "npm run dev",
      ["tab terminal ls"] = "ls",
      ["debug !ls"] = "ls",
      ["write | !ls"] = "ls",
      ["execute '!ls'"] = "ls",
      ["windo !ls"] = "ls",
      ["g/x/!ls"] = "ls",
      ["autocmd vibing BufEnter * ++once !ls"] = "ls",
      ["command! -nargs=1 X !ls"] = "ls",
      ["lua print(1)\n!ls"] = "ls",
      ["make test"] = "make test",
      ["lgrep foo"] = "lgrep foo",
      ["lua vim.fn.system('ls')"] = "ls",
      ["lua vim.fn.system({'ls', '-a'})"] = "ls -a",
      ["call systemlist(\"ls\")"] = "ls",
      ["lua vim.fn.jobstart('ls', { on_exit = f })"] = "ls",
      ["lua vim.cmd('!ls')"] = "ls",
      ["1,$!sort -u"] = "sort -u",
      ["echo system('ls')"] = "ls",
      ["let x = system('ls')"] = "ls",
      ["lua io.popen('ls')"] = "ls",
      ["lua os.execute('ls')"] = "ls",
      ["lua vim.system({'ls'})"] = "ls",
      ["lua << EOF\nlocal x = 1\nos.execute('ls')\nEOF"] = "ls",
    }) do
      assert.equals(expected, shell_command.from_ex(command), command)
    end
  end)

  it("judges the whole text when the command is not one literal", function()
    for _, command in ipairs({
      "3tab terminal ls",
      "Nonexistent foo",
      "exe g:cmd",
      "exe \"!\" . \"ls\"",
      "normal :!ls\r",
      "py3 os.system('ls')",
      "set shell=/bin/zsh",
      "set makeprg=rm",
      "e term://ls",
      "lua vim.cmd.terminal('ls')",
      "lua vim.cmd [[!ls]]",
      "lua vim.fn['system']('ls')",
      "lua local s = vim.fn.system; s('ls')",
      "lua _G['os']['execute']('ls')",
      "call call('system', ['ls'])",
      "echo execute('!ls')",
      "lua vim.uv.spawn('rm', { args = { '-rf', '/' } })",
      "call system('npm ' . 'test')",
      "lua vim.fn.system('ls') os.execute(cmd)",
      "lua vim.fn.system({'ls', extra})",
      "lua vim.api.nvim_cmd({ cmd = '!', args = { 'ls' } }, {})",
    }) do
      local found = shell_command.from_ex(command)
      assert.is_not_nil(found, command)
      for _, prefix in ipairs({ "ls:*", "npm:*", "rm:*" }) do
        assert.is_false(matchers.matches_bash_pattern(found, prefix, "bash_wildcard"), command .. " as " .. found)
      end
    end
  end)

  it("recognizes nothing in ordinary Ex commands", function()
    for _, command in ipairs({
      "write",
      "w! file.txt",
      "edit file.txt",
      "split",
      "wincmd l",
      "set number",
      "lua print(1)",
      "lua vim.lsp.buf.format()",
      "lua << EOF\nlocal x = 1\nprint(x)\nEOF",
      "normal! j",
      "%s/!foo/bar/",
      "g/foo/d",
      "exe \"normal gg\"",
      "help system()",
      "autocmd BufWritePost * lua print(1)",
      "\" a comment",
    }) do
      assert.is_nil(shell_command.from_ex(command), command)
    end
  end)
end)

describe("job_command.from_job", function()
  it("joins the argv and writes the environment in front", function()
    assert.equals("npm test", job_command.from_job({ command = { "npm", "test" } }))
    assert.equals(
      "A=1 PATH=/x npm test",
      job_command.from_job({ command = { "npm", "test" }, env = { PATH = "/x", A = "1" } })
    )
    assert.equals("nvim_job_start", job_command.from_job({ command = {} }))
    assert.equals("nvim_job_start", job_command.from_job({ command = { "npm", "" } }))
  end)
end)
