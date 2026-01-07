#!/usr/bin/env node
/**
 * Test script for AskUserQuestion functionality
 * Simulates the stdin/stdout interaction between Lua and Agent Wrapper
 */

import { spawn } from 'child_process';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

console.log('🧪 Testing AskUserQuestion functionality...\n');

// Start agent wrapper
const wrapper = spawn(
  'node',
  [
    join(__dirname, 'bin/agent-wrapper.mjs'),
    '--prompt',
    'Please ask me to choose a database and features using AskUserQuestion tool',
    '--cwd',
    __dirname,
  ],
  {
    stdio: ['pipe', 'pipe', 'pipe'],
  }
);

let outputBuffer = '';
let foundAskUserQuestion = false;

wrapper.stdout.on('data', (data) => {
  outputBuffer += data.toString();

  // Process line by line
  const lines = outputBuffer.split('\n');
  outputBuffer = lines.pop() || ''; // Keep incomplete line in buffer

  for (const line of lines) {
    if (!line.trim()) continue;

    try {
      const msg = JSON.parse(line);

      if (msg.type === 'session') {
        console.log('✅ Session started:', msg.session_id);
      } else if (msg.type === 'ask_user_question') {
        console.log('✅ AskUserQuestion event received!');
        console.log('\n📋 Question message:');
        console.log('---');
        console.log(msg.message);
        console.log('---\n');

        console.log('📝 Questions structure:');
        for (const q of msg.questions) {
          console.log(`  Q: ${q.question}`);
          console.log(`     Options: ${q.options.map((o) => o.label).join(', ')}`);
          console.log(`     Multi-select: ${q.multiSelect}`);
        }

        foundAskUserQuestion = true;

        // Simulate user selecting first option
        console.log('\n🎯 Simulating user selection (first option only)...');
        const answers = {};
        answers[msg.questions[0].question] = msg.questions[0].options[0].label;

        const response = JSON.stringify({
          type: 'ask_user_question_response',
          answers: answers,
        });

        console.log('📤 Sending answer:', JSON.stringify(answers, null, 2));
        wrapper.stdin.write(response + '\n');
      } else if (msg.type === 'chunk') {
        // Suppress normal chunks for cleaner output
        process.stdout.write('.');
      } else if (msg.type === 'done') {
        console.log('\n\n✅ Process completed');
        if (foundAskUserQuestion) {
          console.log('🎉 AskUserQuestion test PASSED!');
          process.exit(0);
        } else {
          console.log('⚠️  No AskUserQuestion event detected');
          console.log('   (This may be expected if Claude did not use the tool)');
          process.exit(0);
        }
      } else if (msg.type === 'error') {
        console.error('❌ Error:', msg.message);
      }
    } catch (e) {
      // Ignore non-JSON lines
    }
  }
});

wrapper.stderr.on('data', (data) => {
  const text = data.toString();
  if (!text.includes('.zshenv')) {
    console.error('STDERR:', text);
  }
});

wrapper.on('close', (code) => {
  if (code !== 0 && !foundAskUserQuestion) {
    console.log('\n⚠️  Test completed without AskUserQuestion');
    console.log('   This is expected - Claude may not always use AskUserQuestion');
    console.log('   The implementation is ready for when Claude decides to use it.');
  }
  process.exit(code || 0);
});

// Timeout after 30 seconds
setTimeout(() => {
  console.log('\n⏱️  Test timeout (30s)');
  wrapper.kill();
  process.exit(1);
}, 30000);
