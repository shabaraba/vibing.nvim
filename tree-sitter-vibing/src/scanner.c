#include "tree_sitter/parser.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum TokenType {
  FENCED_MARKDOWN_BLOCK,
  TOOL_HEADER_MULTILINE,
};

// A rendered tool call is `<marker> Name(<argument>)`, and the argument is the tool's own input
// verbatim -- for Bash, a shell command, which may run to dozens of lines. Where it ends is
// decided by matching parentheses, and the policy below is the one already measured against real
// chats in `lua/vibing/core/utils/chat_excerpt.lua`: quoted spans and escapes do not count, a
// heredoc body is data rather than code, and past a line limit the whole thing is given up on.
// `tests/lua/infrastructure/treesitter_tool_span_spec.lua` holds the two to the same answers.
#define MAX_LINE_BYTES 2048
#define MAX_TOOL_HEADER_LINES 500
#define MAX_HEREDOCS 8
#define MAX_DELIMITER 64
// Stands in for any codepoint outside ASCII. Nothing below looks at one except to recognise the
// marker glyph, which is only ever asked whether it is ASCII.
#define NON_ASCII '\x01'

void *tree_sitter_vibing_external_scanner_create(void) { return NULL; }

void tree_sitter_vibing_external_scanner_destroy(void *payload) { (void)payload; }

unsigned tree_sitter_vibing_external_scanner_serialize(void *payload, char *buffer) {
  (void)payload;
  (void)buffer;
  return 0;
}

void tree_sitter_vibing_external_scanner_deserialize(void *payload, const char *buffer,
                                                     unsigned length) {
  (void)payload;
  (void)buffer;
  (void)length;
}

static void advance(TSLexer *lexer) { lexer->advance(lexer, false); }

static void consume_line_ending(TSLexer *lexer) {
  if (lexer->lookahead == '\r') {
    advance(lexer);
  }
  if (lexer->lookahead == '\n') {
    advance(lexer);
  }
}

static void consume_to_line_end(TSLexer *lexer) {
  while (!lexer->eof(lexer) && lexer->lookahead != '\r' && lexer->lookahead != '\n') {
    advance(lexer);
  }
  consume_line_ending(lexer);
}

static bool consume_literal(TSLexer *lexer, const char *text) {
  for (const char *character = text; *character != '\0'; character++) {
    if (lexer->lookahead != *character) {
      return false;
    }
    advance(lexer);
  }
  return true;
}

static bool consume_digits(TSLexer *lexer, unsigned count) {
  for (unsigned index = 0; index < count; index++) {
    if (lexer->lookahead < '0' || lexer->lookahead > '9') {
      return false;
    }
    advance(lexer);
  }
  return true;
}

static bool at_header_suffix(TSLexer *lexer) {
  return lexer->eof(lexer) || lexer->lookahead == ' ' || lexer->lookahead == '\r' ||
         lexer->lookahead == '\n';
}

// Match the prefixes reserved by message_header in grammar.js. It is enough to recognize the
// optional HTML-comment separator as a space here: once a chat boundary is seen, an unfinished
// code fence must be handed back to the ordinary document grammar rather than searching later
// messages for an unrelated closing fence.
static bool consume_message_header(TSLexer *lexer) {
  if (!consume_literal(lexer, "## ")) {
    return false;
  }

  bool matched = false;
  switch (lexer->lookahead) {
    case 'U':
      matched = consume_literal(lexer, "User");
      break;
    case 'A':
      matched = consume_literal(lexer, "Assistant");
      break;
    case 'N':
      matched = consume_literal(lexer, "Notice");
      break;
    case 'R':
      advance(lexer);
      if (lexer->lookahead != 'e') {
        break;
      }
      advance(lexer);
      if (lexer->lookahead == 'q') {
        matched = consume_literal(lexer, "quest");
      } else if (lexer->lookahead == 'p') {
        matched = consume_literal(lexer, "port");
      }
      break;
    case 'S':
    case 's': {
      const char *tail = "ummary";
      advance(lexer);
      matched = true;
      for (const char *character = tail; *character != '\0'; character++) {
        int32_t lookahead = lexer->lookahead;
        if (lookahead >= 'A' && lookahead <= 'Z') {
          lookahead += 'a' - 'A';
        }
        if (lookahead != *character) {
          matched = false;
          break;
        }
        advance(lexer);
      }
      break;
    }
    default:
      if (lexer->lookahead >= '0' && lexer->lookahead <= '9') {
        matched = consume_digits(lexer, 4) && consume_literal(lexer, "-") &&
                  consume_digits(lexer, 2) && consume_literal(lexer, "-") &&
                  consume_digits(lexer, 2) && consume_literal(lexer, " ") &&
                  consume_digits(lexer, 2) && consume_literal(lexer, ":") &&
                  consume_digits(lexer, 2) && consume_literal(lexer, ":") &&
                  consume_digits(lexer, 2) && consume_literal(lexer, " ");
        if (matched) {
          if (lexer->lookahead == 'U') {
            matched = consume_literal(lexer, "User");
          } else if (lexer->lookahead == 'A') {
            matched = consume_literal(lexer, "Assistant");
          } else {
            matched = false;
          }
        }
      }
      break;
  }

  return matched && at_header_suffix(lexer);
}

typedef struct {
  char text[MAX_LINE_BYTES];
  unsigned length;
  bool terminated;
} Line;

// Read to the end of the line, keeping its ASCII. A line longer than the buffer is truncated
// rather than refused: a truncated tail can only make the parentheses look unbalanced, which ends
// the scan in the direction that changes nothing.
static void read_line(TSLexer *lexer, Line *line) {
  line->length = 0;
  line->terminated = false;

  while (!lexer->eof(lexer) && lexer->lookahead != '\r' && lexer->lookahead != '\n') {
    if (line->length < MAX_LINE_BYTES - 1) {
      line->text[line->length++] = lexer->lookahead < 0x80 ? (char)lexer->lookahead : NON_ASCII;
    }
    advance(lexer);
  }
  line->text[line->length] = '\0';

  if (lexer->lookahead == '\r' || lexer->lookahead == '\n') {
    consume_line_ending(lexer);
    line->terminated = true;
  }
}

// Drop what must not be counted, in the order the Lua does it: an escaped character first, so an
// escaped quote does not open one, then single-quoted spans, then double-quoted ones. A quote
// with no partner on its own line is left alone -- following one across lines would need a shell
// parser, and the parentheses inside it counting is the conservative answer.
static void strip_uncounted(char *text) {
  char *write = text;
  for (const char *read = text; *read != '\0'; read++) {
    if (*read == '\\' && read[1] != '\0') {
      read++;
      continue;
    }
    *write++ = *read;
  }
  *write = '\0';

  const char quotes[2] = { '\'', '"' };
  for (unsigned index = 0; index < 2; index++) {
    const char quote = quotes[index];
    write = text;
    for (const char *read = text; *read != '\0'; read++) {
      if (*read == quote) {
        const char *closing = strchr(read + 1, quote);
        if (closing != NULL) {
          read = closing;
          continue;
        }
      }
      *write++ = *read;
    }
    *write = '\0';
  }
}

static int paren_balance(const char *text) {
  char scratch[MAX_LINE_BYTES];
  size_t length = strlen(text);
  if (length >= MAX_LINE_BYTES) {
    length = MAX_LINE_BYTES - 1;
  }
  memcpy(scratch, text, length);
  scratch[length] = '\0';
  strip_uncounted(scratch);

  int balance = 0;
  for (const char *character = scratch; *character != '\0'; character++) {
    if (*character == '(') {
      balance++;
    } else if (*character == ')') {
      balance--;
    }
  }
  return balance;
}

static bool is_name_start(char character) {
  return (character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z') ||
         character == '_';
}

static bool is_name_character(char character) {
  return is_name_start(character) || (character >= '0' && character <= '9') || character == '.' ||
         character == ':' || character == '-';
}

// `<marker> Name(`, where the marker is configurable and only required to start outside ASCII --
// the same shape `tool_header` recognises, which is what keeps ordinary Markdown bullets out.
static bool opens_tool_call(const char *text) {
  if (text[0] != NON_ASCII) {
    return false;
  }

  const char *cursor = text;
  while (*cursor != '\0' && *cursor != ' ' && *cursor != '\t') {
    cursor++;
  }
  if (*cursor != ' ') {
    return false;
  }
  cursor++;

  if (!is_name_start(*cursor)) {
    return false;
  }
  while (is_name_character(*cursor)) {
    cursor++;
  }
  return *cursor == '(';
}

// A heredoc body is data, so the parentheses in it are not the command's. Collect what would end
// one; `<<<` is a herestring and opens nothing.
static void collect_heredocs(const char *text, char delimiters[][MAX_DELIMITER], unsigned *count) {
  for (const char *cursor = text; cursor[0] != '\0' && cursor[1] != '\0'; cursor++) {
    if (cursor[0] != '<' || cursor[1] != '<') {
      continue;
    }
    if (cursor[2] == '<') {
      cursor += 2;
      continue;
    }

    const char *name = cursor + 2;
    if (*name == '-') {
      name++;
    }
    while (*name == ' ' || *name == '\t') {
      name++;
    }

    char quote = 0;
    if (*name == '\'' || *name == '"') {
      quote = *name;
      name++;
    }
    if (!is_name_start(*name)) {
      continue;
    }

    const char *end = name;
    while (is_name_start(*end) || (*end >= '0' && *end <= '9')) {
      end++;
    }
    if (quote != 0 && *end != quote) {
      continue;
    }

    size_t length = (size_t)(end - name);
    if (*count < MAX_HEREDOCS && length < MAX_DELIMITER) {
      memcpy(delimiters[*count], name, length);
      delimiters[*count][length] = '\0';
      (*count)++;
    }
    cursor = end - 1;
  }
}

// A heredoc ends on a line holding nothing but its delimiter -- except that the renderer's own
// closing parenthesis lands on that line too when the command ends with the heredoc, so `PY)` both
// ends one and closes the call. A delimiter cannot itself contain a parenthesis, so counting that
// line like any other is what accounts for them.
static bool is_heredoc_terminator(const char *text, const char *delimiter) {
  while (*text == ' ' || *text == '\t') {
    text++;
  }

  size_t length = strlen(delimiter);
  if (strncmp(text, delimiter, length) != 0) {
    return false;
  }
  text += length;

  while (*text == ')' || *text == ' ' || *text == '\t') {
    text++;
  }
  return *text == '\0';
}

// The whole of a rendered call whose argument spans lines. The single-line shape is left to
// `tool_header`, so every call that fits on a line keeps one node type in the tree.
//
// Two answers are looked for at once, because the better one is not always available. The
// parentheses closing is the call really ending. The first line whose last character is `)` is
// the guess this rule used to be written as, kept as a floor for arguments the paren count cannot
// follow -- a quote left open, a heredoc nested past the limit. It is marked as it goes past so
// that reaching the end of what may be scanned still yields a block rather than nothing.
static bool scan_tool_header_multiline(TSLexer *lexer) {
  Line line;
  read_line(lexer, &line);
  if (!line.terminated || !opens_tool_call(line.text)) {
    return false;
  }

  char delimiters[MAX_HEREDOCS][MAX_DELIMITER];
  unsigned pending = 0;
  int balance = paren_balance(line.text);
  collect_heredocs(line.text, delimiters, &pending);
  if (balance <= 0 && pending == 0) {
    return false;
  }

  bool marked = false;
  for (unsigned index = 0; index < MAX_TOOL_HEADER_LINES; index++) {
    // A chat boundary ends every construct. Without it an argument that never closes reads the
    // rest of the conversation looking for one, and the `## Assistant` it passes stops being a
    // message header at all.
    //
    // It has to be the real thing and not any `##`: a call can be posting Markdown
    // (`gh api /markdown -f text='## Requirements`), and treating its headings as boundaries
    // leaves that call unterminated and so unfolded. `consume_message_header` eats part of the
    // line when it says no, which costs nothing -- what it ate is `## ` and letters, and the rest
    // of the line is read below.
    if (lexer->lookahead == '#' && consume_message_header(lexer)) {
      break;
    }

    read_line(lexer, &line);
    if (!line.terminated) {
      break;
    }

    if (pending > 0) {
      if (!is_heredoc_terminator(line.text, delimiters[0])) {
        continue;
      }
      memmove(delimiters[0], delimiters[1], (MAX_HEREDOCS - 1) * MAX_DELIMITER);
      pending--;
      if (pending > 0) {
        continue;
      }
    }
    balance += paren_balance(line.text);

    if (balance <= 0) {
      lexer->mark_end(lexer);
      lexer->result_symbol = TOOL_HEADER_MULTILINE;
      return true;
    }

    if (!marked && line.length > 0 && line.text[line.length - 1] == ')') {
      lexer->mark_end(lexer);
      marked = true;
    }
    if (pending == 0) {
      collect_heredocs(line.text, delimiters, &pending);
    }
  }

  if (!marked) {
    return false;
  }
  lexer->result_symbol = TOOL_HEADER_MULTILINE;
  return true;
}

bool tree_sitter_vibing_external_scanner_scan(void *payload, TSLexer *lexer,
                                              const bool *valid_symbols) {
  (void)payload;

  if (lexer->get_column(lexer) != 0) {
    return false;
  }

  // The two tokens are told apart by their first codepoint -- a fence opens with a backtick, a
  // tilde or a space, a tool call with the marker glyph, which must be outside ASCII. So neither
  // scan ever has to be unwound before the other is tried.
  if (lexer->lookahead >= 0x80) {
    return valid_symbols[TOOL_HEADER_MULTILINE] && scan_tool_header_multiline(lexer);
  }

  if (!valid_symbols[FENCED_MARKDOWN_BLOCK]) {
    return false;
  }

  unsigned indent = 0;
  while (lexer->lookahead == ' ' && indent < 3) {
    advance(lexer);
    indent++;
  }

  const int32_t marker = lexer->lookahead;
  if (marker != '`' && marker != '~') {
    return false;
  }

  unsigned opening_length = 0;
  while (lexer->lookahead == marker) {
    advance(lexer);
    opening_length++;
  }
  if (opening_length < 3) {
    return false;
  }

  // CommonMark does not allow a backtick in the info string of a backtick fence.
  while (!lexer->eof(lexer) && lexer->lookahead != '\r' && lexer->lookahead != '\n') {
    if (marker == '`' && lexer->lookahead == '`') {
      return false;
    }
    advance(lexer);
  }
  consume_line_ending(lexer);

  while (!lexer->eof(lexer)) {
    if (lexer->lookahead == '#') {
      if (consume_message_header(lexer)) {
        return false;
      }
      consume_to_line_end(lexer);
      continue;
    }

    indent = 0;
    while (lexer->lookahead == ' ' && indent < 3) {
      advance(lexer);
      indent++;
    }

    unsigned closing_length = 0;
    while (lexer->lookahead == marker) {
      advance(lexer);
      closing_length++;
    }

    if (closing_length >= opening_length) {
      bool only_whitespace = true;
      while (!lexer->eof(lexer) && lexer->lookahead != '\r' && lexer->lookahead != '\n') {
        if (lexer->lookahead != ' ' && lexer->lookahead != '\t') {
          only_whitespace = false;
        }
        advance(lexer);
      }
      if (only_whitespace) {
        consume_line_ending(lexer);
        lexer->mark_end(lexer);
        lexer->result_symbol = FENCED_MARKDOWN_BLOCK;
        return true;
      }
    }

    consume_to_line_end(lexer);
  }

  // An unfinished fence stays ordinary Markdown so a later chat header can still terminate it.
  return false;
}
