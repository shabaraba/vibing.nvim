#include "tree_sitter/parser.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

enum TokenType {
  FENCED_MARKDOWN_BLOCK,
};

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

bool tree_sitter_vibing_external_scanner_scan(void *payload, TSLexer *lexer,
                                              const bool *valid_symbols) {
  (void)payload;

  if (!valid_symbols[FENCED_MARKDOWN_BLOCK] || lexer->get_column(lexer) != 0) {
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
