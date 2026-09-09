([(message_header)
  (fenced_markdown_block)
  (markdown_chunk)] @injection.content
  (#set! injection.include-children)
  (#set! injection.language "markdown"))
