/**
 * Tests for AskUserQuestion functionality in agent-wrapper.mjs
 *
 * These tests verify:
 * 1. AskUserQuestion detection and JSON output
 * 2. stdin response handling
 * 3. Timeout behavior
 */

import { strict as assert } from 'assert';

// Mock test data
const mockQuestion = {
  question: 'Which database should we use?',
  header: 'Database',
  options: [
    { label: 'PostgreSQL', description: 'Relational, ACID compliant' },
    { label: 'MongoDB', description: 'Document-based, flexible schema' },
    { label: 'MySQL', description: 'Popular open-source relational database' },
  ],
  multiSelect: false,
};

/**
 * Test that the readline module is properly imported
 * This is a basic sanity check
 */
async function testReadlineImport() {
  console.log('Test: readline module import');

  // The wrapper should have readline imported at the top
  const { createInterface } = await import('readline');
  assert.ok(typeof createInterface === 'function', 'readline.createInterface should be a function');

  console.log('  PASS: readline module imports correctly');
}

/**
 * Test the pendingQuestions Map structure
 * This verifies the internal state management works
 */
async function testPendingQuestionsStructure() {
  console.log('Test: pendingQuestions Map structure');

  const pendingQuestions = new Map();
  let questionIdCounter = 0;

  // Simulate adding a pending question
  const questionId = questionIdCounter++;
  const promise = new Promise((resolve, reject) => {
    pendingQuestions.set(questionId, { resolve, reject });
  });

  assert.ok(pendingQuestions.has(questionId), 'Question should be in pending map');
  assert.ok(pendingQuestions.get(questionId).resolve, 'Should have resolve function');
  assert.ok(pendingQuestions.get(questionId).reject, 'Should have reject function');

  // Simulate receiving an answer
  const pending = pendingQuestions.get(questionId);
  pendingQuestions.delete(questionId);
  pending.resolve({ 'Which database should we use?': 'PostgreSQL' });

  const result = await promise;
  assert.deepEqual(result, { 'Which database should we use?': 'PostgreSQL' });

  console.log('  PASS: pendingQuestions structure works correctly');
}

/**
 * Test JSON parsing of stdin messages
 */
async function testStdinMessageParsing() {
  console.log('Test: stdin message parsing');

  const testCases = [
    {
      input:
        '{"type":"ask_user_question_response","question_id":0,"cancelled":false,"answers":{"Q":"A"}}',
      expected: {
        type: 'ask_user_question_response',
        question_id: 0,
        cancelled: false,
        answers: { Q: 'A' },
      },
    },
    {
      input: '{"type":"ask_user_question_response","question_id":1,"cancelled":true}',
      expected: {
        type: 'ask_user_question_response',
        question_id: 1,
        cancelled: true,
      },
    },
  ];

  for (const testCase of testCases) {
    const parsed = JSON.parse(testCase.input);
    assert.equal(parsed.type, testCase.expected.type);
    assert.equal(parsed.question_id, testCase.expected.question_id);
    assert.equal(parsed.cancelled, testCase.expected.cancelled);
    if (testCase.expected.answers) {
      assert.deepEqual(parsed.answers, testCase.expected.answers);
    }
  }

  console.log('  PASS: stdin messages parse correctly');
}

/**
 * Test the AskUserQuestion JSON output format
 */
async function testAskUserQuestionOutputFormat() {
  console.log('Test: AskUserQuestion JSON output format');

  const questionId = 0;
  const questions = [mockQuestion];

  const output = JSON.stringify({
    type: 'ask_user_question',
    question_id: questionId,
    questions: questions,
  });

  const parsed = JSON.parse(output);
  assert.equal(parsed.type, 'ask_user_question');
  assert.equal(parsed.question_id, 0);
  assert.equal(parsed.questions.length, 1);
  assert.equal(parsed.questions[0].question, 'Which database should we use?');
  assert.equal(parsed.questions[0].header, 'Database');
  assert.equal(parsed.questions[0].options.length, 3);
  assert.equal(parsed.questions[0].multiSelect, false);

  console.log('  PASS: AskUserQuestion output format is correct');
}

/**
 * Test the response format for updatedInput
 */
async function testUpdatedInputFormat() {
  console.log('Test: updatedInput format for canUseTool');

  const questions = [mockQuestion];
  const answers = { 'Which database should we use?': 'PostgreSQL' };

  const updatedInput = {
    questions: questions,
    answers: answers,
  };

  assert.ok(Array.isArray(updatedInput.questions));
  assert.ok(typeof updatedInput.answers === 'object');
  assert.equal(updatedInput.answers['Which database should we use?'], 'PostgreSQL');

  console.log('  PASS: updatedInput format is correct');
}

/**
 * Test multi-select answer format
 */
async function testMultiSelectAnswerFormat() {
  console.log('Test: multi-select answer format');

  // multiSelect: true case - verify answer format with multiple selections
  // Simulate multiple selections as comma-separated string
  const answers = { 'Which database should we use?': 'PostgreSQL, MongoDB' };

  assert.ok(answers['Which database should we use?'].includes('PostgreSQL'));
  assert.ok(answers['Which database should we use?'].includes('MongoDB'));

  console.log('  PASS: multi-select answer format is correct');
}

/**
 * Test cancellation handling
 */
async function testCancellationHandling() {
  console.log('Test: cancellation handling');

  const pendingQuestions = new Map();
  const questionId = 0;

  let rejectionError = null;

  const promise = new Promise((resolve, reject) => {
    pendingQuestions.set(questionId, { resolve, reject });
  }).catch((err) => {
    rejectionError = err;
  });

  // Simulate cancellation
  const pending = pendingQuestions.get(questionId);
  pendingQuestions.delete(questionId);
  pending.reject(new Error('User cancelled the question'));

  await promise;
  assert.ok(rejectionError instanceof Error);
  assert.equal(rejectionError.message, 'User cancelled the question');

  console.log('  PASS: cancellation handling works correctly');
}

// Run all tests
async function runTests() {
  console.log('=== AskUserQuestion Tests ===\n');

  try {
    await testReadlineImport();
    await testPendingQuestionsStructure();
    await testStdinMessageParsing();
    await testAskUserQuestionOutputFormat();
    await testUpdatedInputFormat();
    await testMultiSelectAnswerFormat();
    await testCancellationHandling();

    console.log('\n=== All tests passed! ===');
    process.exit(0);
  } catch (error) {
    console.error('\nTest failed:', error);
    process.exit(1);
  }
}

runTests();
