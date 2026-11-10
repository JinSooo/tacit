/**
 * 先隐藏、过一会儿才提交的操作：等待期间可以撤销；离开页面时立即提交。
 * 同一 id 再次加入会替换之前的操作并重新计时。
 */
export interface UndoEntry<T> { id: string; value: T }
export function createUndoQueue<T>(options: {
  delay: number;
  commit: (id: string, value: T, flushing: boolean) => void;
  onChange: (entries: UndoEntry<T>[]) => void;
  schedule?: (run: () => void, ms: number) => unknown;
  cancel?: (timer: unknown) => void;
}) {
  const schedule = options.schedule ?? ((run, ms) => setTimeout(run, ms));
  const cancel = options.cancel ?? (timer => clearTimeout(timer as ReturnType<typeof setTimeout>));
  const entries = new Map<string, { value: T; timer: unknown }>();
  const changed = () => options.onChange([...entries].map(([id, entry]) => ({ id, value: entry.value })));
  function fire(id: string, flushing: boolean) {
    const entry = entries.get(id);
    if (!entry) return;
    cancel(entry.timer);
    entries.delete(id);
    changed();
    options.commit(id, entry.value, flushing);
  }
  return {
    add(id: string, value: T) {
      const previous = entries.get(id);
      if (previous) cancel(previous.timer);
      entries.set(id, { value, timer: schedule(() => fire(id, false), options.delay) });
      changed();
    },
    undo(id: string): boolean {
      const entry = entries.get(id);
      if (!entry) return false;
      cancel(entry.timer);
      entries.delete(id);
      changed();
      return true;
    },
    flush() { for (const id of [...entries.keys()]) fire(id, true); },
    has: (id: string) => entries.has(id),
  };
}
export type UndoQueue<T> = ReturnType<typeof createUndoQueue<T>>;
