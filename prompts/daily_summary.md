# Daily Summary Request for {{date}}

Below are conversation pairs from today's development sessions, grouped by project.
Please analyze them and create a development journal following engineering best practices.

## Required Output Format

Use this structure for each project:

```markdown
## [Project Name]

### What I Did (やったこと)

- [Feature/Task] Implementation detail with file/function names
  - Specific changes made
  - Progress: XX% complete (if applicable)

### What I Learned (わかったこと)

- Technical insights, discoveries, or new knowledge gained
- Solutions to problems encountered
- Best practices or patterns identified

### Challenges & Solutions (課題と解決)

- **Challenge:** Specific problem description
  - **Solution:** How it was resolved
  - **Root Cause:** Why it happened (if identified)

### Next Actions (つぎにやること)

- [ ] Specific next steps with action items
- [ ] Follow-up tasks or improvements needed
- [ ] Blockers to address

### Notes

- Additional context, ideas, or observations
- Links to related discussions or documentation
```

**Important Guidelines:**

- **Structure by project**: Use `##` headers for each project name
- **Be specific**: Include file names, function names, error messages, etc.
- **Focus on impact**: What changed? What was learned? What's next?
- **Use checkboxes**: Format next actions as `- [ ]` task items
- **Quantify when possible**: Progress percentages, metrics, numbers
- **Omit empty sections**: Skip sections with no content
- **Write concisely**: Use bullet points, not paragraphs

**Format Standards:**

- Code/file references: Use `backticks`
- Task items: Use `- [ ]` for actionable items
- Completed items: Use `- [x]` if tracking completion
- Importance: Use **bold** for key points

{{language_instruction}}

---

# Today's Conversations

{{conversations}}
