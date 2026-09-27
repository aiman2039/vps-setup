// managed by vps-setup (13-notify) - safe to re-run, manual edits will be overwritten.
// Pings ntfy when pi finishes a turn, needs approval, or asks a question.
import { execFile } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';

function ping(detail: string): void {
  const bin = join(homedir(), '.local', 'bin', 'ntfy-wait');
  const child = execFile(bin, ['pi', detail], { timeout: 8000 }, () => {});
  child.on('error', () => {});
}

export default function (pi): void {
  pi.on('agent_end', () => ping('turn finished'));
  pi.on('tool_approval_requested', (event) => ping('approval: ' + (event?.toolName ?? 'tool')));
  pi.on('ui_prompt_start', () => ping('question waiting'));
}
