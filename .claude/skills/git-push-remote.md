# Git Push for Claude Code on the Web

This skill provides Git push operations optimized for Claude Code on the web environment with proper branch naming and retry logic.

## When to Use

This skill is automatically activated when running in Claude Code on the web environment (`CLAUDE_CODE_REMOTE=true`).

## Branch Naming Requirements

When pushing to remote in Claude Code on the web:
- Branch names MUST start with `claude/`
- Branch names MUST end with a matching session ID
- Example: `claude/feature-name-abc123` where `abc123` is the session ID
- Pushing to branches without this pattern will fail with HTTP 403

## Environment Detection

```bash
# Check if running in Claude Code on the web
if [ "$CLAUDE_CODE_REMOTE" = "true" ]; then
  echo "Running in Claude Code on the web"
fi
```

## Push with Retry Logic

Claude Code on the web may experience transient network issues. Always use retry logic:

```bash
# Function to push with exponential backoff retry
push_with_retry() {
  local branch="$1"
  local max_retries=4
  local delays=(2 4 8 16)

  for i in $(seq 0 $((max_retries - 1))); do
    if [ $i -gt 0 ]; then
      local delay=${delays[$((i-1))]}
      echo "Retry $i after ${delay}s..."
      sleep $delay
    fi

    if git push -u origin "$branch" 2>&1; then
      echo "Push successful!"
      return 0
    fi
  done

  echo "Push failed after $max_retries attempts"
  return 1
}

# Usage
push_with_retry "claude/my-feature-abc123"
```

## Complete Workflow Example

```bash
#!/bin/bash

# Only apply this logic in Claude Code on the web
if [ "$CLAUDE_CODE_REMOTE" != "true" ]; then
  # Normal git push in local environment
  git push -u origin "$(git branch --show-current)"
  exit $?
fi

# Claude Code on the web environment
SESSION_ID="${CLAUDE_SESSION_ID:-9GOGf}"  # Get from environment or use default
CURRENT_BRANCH="$(git branch --show-current)"

# Check if branch name follows the required pattern
if [[ ! "$CURRENT_BRANCH" =~ ^claude/.+-[a-zA-Z0-9]+$ ]]; then
  echo "Error: Branch name must match pattern 'claude/*-<sessionId>'"
  echo "Current branch: $CURRENT_BRANCH"
  echo "Creating properly named branch..."

  # Extract feature name from current branch
  FEATURE_NAME="${CURRENT_BRANCH//[^a-zA-Z0-9-]/-}"
  NEW_BRANCH="claude/${FEATURE_NAME}-${SESSION_ID}"

  # Create and checkout new branch
  git checkout -b "$NEW_BRANCH"
  CURRENT_BRANCH="$NEW_BRANCH"
fi

# Push with retry logic
echo "Pushing branch: $CURRENT_BRANCH"
for i in 0 1 2 3; do
  if [ $i -gt 0 ]; then
    delay=$((2 ** i))
    echo "Retry $i after ${delay}s..."
    sleep $delay
  fi

  if git push -u origin "$CURRENT_BRANCH" 2>&1; then
    echo "✅ Push successful!"
    exit 0
  fi

  # Check if it's a 403 error (branch name issue) or network error
  if git push -u origin "$CURRENT_BRANCH" 2>&1 | grep -q "403"; then
    echo "❌ HTTP 403 - Branch name may not follow required pattern"
    echo "Expected pattern: claude/*-<sessionId>"
    exit 1
  fi
done

echo "❌ Push failed after 4 attempts"
exit 1
```

## Common Issues

### 1. HTTP 403 Error

**Cause**: Branch name doesn't match required pattern `claude/*-<sessionId>`

**Solution**: Create a new branch with proper naming:
```bash
SESSION_ID="abc123"  # Your session ID
git checkout -b "claude/my-feature-${SESSION_ID}"
git push -u origin "claude/my-feature-${SESSION_ID}"
```

### 2. Network Timeout

**Cause**: Transient network issues in web environment

**Solution**: Use retry logic with exponential backoff (provided above)

### 3. "Everything up-to-date" but push fails

**Cause**: Local branch is already synced but push command fails due to network

**Solution**: This is safe to ignore if you see "Everything up-to-date"

## Integration with Git Workflow

When committing and pushing in Claude Code on the web:

```bash
# 1. Make changes
git add .
git commit -m "Your commit message"

# 2. Ensure you're on a properly named branch
if [ "$CLAUDE_CODE_REMOTE" = "true" ]; then
  BRANCH="$(git branch --show-current)"
  if [[ ! "$BRANCH" =~ ^claude/ ]]; then
    echo "Creating claude/ branch..."
    git checkout -b "claude/${BRANCH}-${CLAUDE_SESSION_ID}"
  fi
fi

# 3. Push with retry
if [ "$CLAUDE_CODE_REMOTE" = "true" ]; then
  # Use retry logic (see above)
  push_with_retry "$(git branch --show-current)"
else
  # Normal push
  git push -u origin "$(git branch --show-current)"
fi
```

## Helper Function for Bash Tool

Add this to your bash commands when working in Claude Code on the web:

```bash
# Smart push that handles Claude Code on the web constraints
smart_push() {
  if [ "$CLAUDE_CODE_REMOTE" = "true" ]; then
    BRANCH="$(git branch --show-current)"

    # Validate branch name
    if [[ ! "$BRANCH" =~ ^claude/.+-[a-zA-Z0-9]+$ ]]; then
      echo "❌ Invalid branch name for Claude Code on the web: $BRANCH"
      echo "Use pattern: claude/<feature-name>-<sessionId>"
      return 1
    fi

    # Retry push up to 4 times with exponential backoff
    for attempt in 1 2 3 4; do
      if [ $attempt -gt 1 ]; then
        delay=$((2 ** (attempt - 1)))
        echo "Retrying after ${delay}s (attempt $attempt/4)..."
        sleep $delay
      fi

      if git push -u origin "$BRANCH"; then
        echo "✅ Push successful!"
        return 0
      fi
    done

    echo "❌ Push failed after 4 attempts"
    return 1
  else
    # Local environment - normal push
    git push -u origin "$(git branch --show-current)"
  fi
}

# Usage: just call smart_push
smart_push
```
