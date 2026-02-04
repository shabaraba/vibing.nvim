# Daily Summary Request for {{date}}

Analyze the development conversations below and extract structured data.

## CRITICAL: Output Format

You MUST output ONLY a valid JSON object. No markdown, no explanation, no text before or after.

```json
{
  "projects": [
    {
      "name": "project-name",
      "what_i_did": [
        "Specific task or feature implemented",
        "Another accomplishment with file/function names"
      ],
      "what_i_learned": ["Technical insight or discovery", "Best practice identified"],
      "challenges": [
        {
          "problem": "What went wrong",
          "solution": "How it was resolved",
          "root_cause": "Why it happened (optional)"
        }
      ],
      "next_actions": ["Specific next step", "Follow-up task"],
      "notes": ["Additional observations (optional)"]
    }
  ]
}
```

## Extraction Rules

1. **Group by project**: Each distinct project gets its own object
2. **Be specific**: Include file names, function names, actual values
3. **Focus on outcomes**: Extract what was DONE, not the process
4. **Exclude noise**:
   - NO tool execution logs (`📄 Read`, `⏺ Bash`, `📝 Write`, etc.)
   - NO meta-commentary ("Let me check...", "I'll now...")
   - NO raw command output
5. **Empty arrays are OK**: Use `[]` for sections with no content
6. **Concise strings**: Each array item should be 1-2 sentences max

{{language_instruction}}

---

# Today's Conversations

{{conversations}}
