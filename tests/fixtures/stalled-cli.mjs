import { createInterface } from 'node:readline';

const emit = (message) => process.stdout.write(`${JSON.stringify(message)}\n`);
createInterface({ input: process.stdin }).on('line', (line) => {
  const prompt = JSON.parse(line);
  if (prompt.type !== 'user') return;
  emit({ type: 'system', subtype: 'init', session_id: 'stall-fixture-session' });
  emit({
    type: 'stream_event',
    event: {
      type: 'content_block_delta',
      delta: { type: 'text_delta', text: 'fixture response' },
    },
  });
  if (prompt.message.content.includes('STALL_FIXTURE')) return;
  emit({ type: 'result', subtype: 'success', session_id: 'stall-fixture-session' });
});
