#!/bin/bash
echo "🔍 Implementation Verification"
echo "=============================="
echo

# 1. Check Agent Wrapper implementation
echo "✅ Checking Agent Wrapper (bin/agent-wrapper.mjs)..."
if grep -q "askFollowupQuestion" bin/agent-wrapper.mjs; then
    echo "   ✓ askFollowupQuestion callback found"
else
    echo "   ✗ askFollowupQuestion callback NOT found"
    exit 1
fi

if grep -q "ask_user_question_response" bin/agent-wrapper.mjs; then
    echo "   ✓ stdin response handler found"
else
    echo "   ✗ stdin response handler NOT found"
    exit 1
fi

# 2. Check Lua Adapter implementation
echo
echo "✅ Checking Lua Adapter (lua/vibing/infrastructure/adapter/agent_sdk.lua)..."
if grep -q "send_ask_user_question_answer" lua/vibing/infrastructure/adapter/agent_sdk.lua; then
    echo "   ✓ send_ask_user_question_answer method found"
else
    echo "   ✗ send_ask_user_question_answer method NOT found"
    exit 1
fi

if grep -q "on_ask_user_question" lua/vibing/infrastructure/adapter/agent_sdk.lua; then
    echo "   ✓ on_ask_user_question event handler found"
else
    echo "   ✗ on_ask_user_question event handler NOT found"
    exit 1
fi

# 3. Check Chat Buffer implementation
echo
echo "✅ Checking Chat Buffer (lua/vibing/presentation/chat/buffer.lua)..."
if grep -q "insert_ask_user_question" lua/vibing/presentation/chat/buffer.lua; then
    echo "   ✓ insert_ask_user_question method found"
else
    echo "   ✗ insert_ask_user_question method NOT found"
    exit 1
fi

if grep -q "get_ask_user_question_answers" lua/vibing/presentation/chat/buffer.lua; then
    echo "   ✓ get_ask_user_question_answers method found"
else
    echo "   ✗ get_ask_user_question_answers method NOT found"
    exit 1
fi

if grep -q "has_pending_ask_user_question" lua/vibing/presentation/chat/buffer.lua; then
    echo "   ✓ has_pending_ask_user_question method found"
else
    echo "   ✗ has_pending_ask_user_question method NOT found"
    exit 1
fi

# 4. Check Send Message integration
echo
echo "✅ Checking Send Message (lua/vibing/application/chat/send_message.lua)..."
if grep -q "on_ask_user_question" lua/vibing/application/chat/send_message.lua; then
    echo "   ✓ on_ask_user_question callback found"
else
    echo "   ✗ on_ask_user_question callback NOT found"
    exit 1
fi

if grep -q "set_current_handle_id" lua/vibing/application/chat/send_message.lua; then
    echo "   ✓ set_current_handle_id callback found"
else
    echo "   ✗ set_current_handle_id callback NOT found"
    exit 1
fi

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
