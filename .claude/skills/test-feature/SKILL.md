---
name: test-feature
description: Test New Feature
---

# Test New Feature

Quick workflow for testing vibing.nvim features after implementation.

## When to Use

- User requests to test a newly implemented feature
- After completing feature development
- Before creating a PR

## Workflow

1. **Reload plugin**

   ```
   :Lazy reload vibing.nvim
   ```

2. **Execute feature manually**
   - Guide user through steps to trigger the feature
   - Observe behavior

3. **Check for errors**

   ```javascript
   const diagnostics = await use_mcp_tool('vibing-nvim', 'nvim_diagnostics', {
     rpc_port: rpcPort,
   });
   ```

4. **Verify expected behavior**
   - Compare actual vs expected results
   - Report findings to user

5. **Run automated tests**
   ```bash
   npm test
   ```

## Success Criteria

- ✅ Feature works as expected
- ✅ No errors in diagnostics
- ✅ All tests pass
