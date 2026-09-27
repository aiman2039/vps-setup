// managed by vps-setup (13-notify) - safe to re-run, manual edits will be overwritten.
// Pings ntfy when opencode goes idle or waits on a permission/question.
import { execFile } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';

const TYPES = ['session.idle', 'permission.asked', 'permission.v2.asked', 'question.asked', 'question.v2.asked'];

function ping(detail) {
  const bin = join(homedir(), '.local', 'bin', 'ntfy-wait');
  const child = execFile(bin, ['opencode', detail], { timeout: 8000 }, () => {});
  child.on('error', () => {});
}

export default {
  id: 'ntfy-wait',
  async setup(ctx) {
    const c = new AbortController();
    void (async () => {
      try {
        for await (const event of ctx.event.subscribe({ signal: c.signal })) {
          if (event && TYPES.includes(event.type)) ping(event.type);
        }
      } catch {
        /* aborted on unload */
      }
    })();
    return () => c.abort();
  },
};
