import { query } from '@anthropic-ai/claude-agent-sdk';

for await (const message of query({
  prompt: 'Say hi',
  options: { allowedTools: [] },
})) {
  console.log(
    JSON.stringify({
      type: message.type,
      subtype: message.subtype,
      hasResult: message.result !== undefined,
      hasMessage: message.message !== undefined,
    })
  );
}
