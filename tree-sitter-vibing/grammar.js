/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

/**
 * A deliberately small outer grammar for vibing.nvim chat files.
 *
 * It only owns chat boundaries and rendered tool blocks. Markdown remains an
 * injected language, so its grammar and queries do not need to be duplicated.
 */
module.exports = grammar({
  name: 'vibing',

  extras: (_) => [],

  externals: ($) => [$.fenced_markdown_block, $.tool_header_multiline],

  rules: {
    document: ($) =>
      repeat(
        choice(
          $.message_header,
          $.fenced_markdown_block,
          $.tool_block,
          $.thinking_block,
          $.markdown_chunk
        )
      ),

    message_header: (_) =>
      token(
        prec(
          4,
          /## ((User|Assistant|Request|Report|Notice|[Ss][Uu][Mm][Mm][Aa][Rr][Yy])( <!-- [^\r\n]* -->)?|[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9] (User|Assistant))\r?\n/
        )
      ),

    // A call whose argument spans lines belongs to the external scanner. Where it ends is a
    // question of matching parentheses, which no regular expression answers, and the rule that
    // was written as one ended a shell script at its first `foo(x)` -- and, when nothing closed,
    // ran on through the next `## Assistant` and took the chat boundary with it.
    tool_block: ($) =>
      seq(
        choice($.tool_header, $.tool_header_multiline),
        optional(seq($.tool_result, repeat($.tool_result_continuation)))
      ),

    // Tool markers are configurable, so recognise the rendered shape rather
    // than a fixed glyph. Requiring a non-ASCII first codepoint avoids treating
    // ordinary Markdown bullets such as "- fix(input)" as tool calls.
    tool_header: (_) =>
      token(prec(4, /[^\x00-\x7f\s][^ \t\r\n]* [A-Za-z_][A-Za-z0-9_.:-]*\([^\r\n]*\)\r?\n/)),

    tool_result: (_) => token(prec(3, /  ⎿[^\r\n]*\r?\n/)),
    tool_result_continuation: (_) => token(prec(3, /     [^\r\n]*\r?\n/)),

    // Reasoning has no terminator, so `event_renderer.lua` marks every line of it rather than
    // only the first. Outranks `tool_header`, whose shape a marked line can otherwise match
    // ("💭 Foo(bar)").
    thinking_block: ($) => prec.right(repeat1($.thinking_line)),

    thinking_line: (_) => token(prec(5, /💭[^\r\n]*\r?\n/)),

    markdown_chunk: ($) => prec.right(repeat1($.markdown_line)),

    markdown_line: (_) => choice(token(prec(-1, /[^\r\n]*\r?\n/)), token(prec(-1, /[^\r\n]+/))),
  },
});
