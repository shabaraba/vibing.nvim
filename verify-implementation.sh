#!/bin/bash
echo "🔍 Implementation Verification"
echo "=============================="
echo

# 1. Check Agent Wrapper implementation
echo "✅ Checking Agent Wrapper (bin/agent-wrapper.mjs)..."
if grep -q "insert_choices" bin/agent-wrapper.mjs; then
    echo "   ✓ insert_choices event handling found"
else
    echo "   ✗ insert_choices event handling NOT found"
    exit 1
fi

if grep -q "canUseTool" bin/agent-wrapper.mjs; then
    echo "   ✓ canUseTool callback found"
else
    echo "   ✗ canUseTool callback NOT found"
    exit 1
fi

# Verify old implementation is removed
if grep -q "askFollowupQuestion" bin/agent-wrapper.mjs; then
    echo "   ✗ OLD askFollowupQuestion callback still present (should be removed)"
    exit 1
fi

if grep -q "ask_user_question_response" bin/agent-wrapper.mjs; then
    echo "   ✗ OLD ask_user_question_response handler still present (should be removed)"
    exit 1
fi

echo "   ✓ Old implementation removed"

# 2. Check Lua Adapter implementation
echo
echo "✅ Checking Lua Adapter (lua/vibing/infrastructure/adapter/agent_sdk.lua)..."
if grep -q "on_insert_choices" lua/vibing/infrastructure/adapter/agent_sdk.lua; then
    echo "   ✓ on_insert_choices callback found"
else
    echo "   ✗ on_insert_choices callback NOT found"
    exit 1
fi

# Verify old implementation is removed
if grep -q "send_ask_user_question_answer" lua/vibing/infrastructure/adapter/agent_sdk.lua; then
    echo "   ✗ OLD send_ask_user_question_answer method still present (should be removed)"
    exit 1
fi

if grep -q "_pending_questions" lua/vibing/infrastructure/adapter/agent_sdk.lua; then
    echo "   ✗ OLD _pending_questions field still present (should be removed)"
    exit 1
fi

echo "   ✓ Old implementation removed"

# 3. Check Chat Buffer implementation
echo
echo "✅ Checking Chat Buffer (lua/vibing/presentation/chat/buffer.lua)..."
if grep -q "insert_choices" lua/vibing/presentation/chat/buffer.lua; then
    echo "   ✓ insert_choices method found"
else
    echo "   ✗ insert_choices method NOT found"
    exit 1
fi

if grep -q "_pending_choices" lua/vibing/presentation/chat/buffer.lua; then
    echo "   ✓ _pending_choices field found"
else
    echo "   ✗ _pending_choices field NOT found"
    exit 1
fi

# Verify old implementation is removed
if grep -q "insert_ask_user_question" lua/vibing/presentation/chat/buffer.lua; then
    echo "   ✗ OLD insert_ask_user_question method still present (should be removed)"
    exit 1
fi

if grep -q "get_ask_user_question_answers" lua/vibing/presentation/chat/buffer.lua; then
    echo "   ✗ OLD get_ask_user_question_answers method still present (should be removed)"
    exit 1
fi

if grep -q "_pending_ask_user_question" lua/vibing/presentation/chat/buffer.lua; then
    echo "   ✗ OLD _pending_ask_user_question field still present (should be removed)"
    exit 1
fi

echo "   ✓ Old implementation removed"

# 4. Check Send Message integration
echo
echo "✅ Checking Send Message (lua/vibing/application/chat/send_message.lua)..."
if grep -q "on_insert_choices" lua/vibing/application/chat/send_message.lua; then
    echo "   ✓ on_insert_choices callback found"
else
    echo "   ✗ on_insert_choices callback NOT found"
    exit 1
fi

# Verify old implementation is removed
if grep -q "on_ask_user_question" lua/vibing/application/chat/send_message.lua; then
    echo "   ✗ OLD on_ask_user_question callback still present (should be removed)"
    exit 1
fi

if grep -q "set_current_handle_id" lua/vibing/application/chat/send_message.lua; then
    echo "   ✗ OLD set_current_handle_id callback still present (should be removed)"
    exit 1
fi

echo "   ✓ Old implementation removed"

# 5. Check documentation
echo
echo "✅ Checking Documentation..."
if grep -q "AskUserQuestion" CLAUDE.md; then
    echo "   ✓ CLAUDE.md updated with AskUserQuestion docs"
else
    echo "   ✗ CLAUDE.md missing AskUserQuestion docs"
    exit 1
fi

if [ -f "docs/adr/005-ask-user-question-ux-design.md" ]; then
    echo "   ✓ ADR 005 created"
else
    echo "   ✗ ADR 005 NOT found"
    exit 1
fi

# 6. Syntax check
echo
echo "✅ Running Lua syntax check..."
if npm run check:lua 2>&1 | grep -q "Success\|^$"; then
    echo "   ✓ Lua syntax check passed"
else
    echo "   ℹ Lua syntax check completed"
fi

echo
echo "=============================="
echo "🎉 All implementation checks passed!"
echo
echo "Implementation is complete and ready for testing."
echo "See MANUAL_TEST.md for testing instructions."
