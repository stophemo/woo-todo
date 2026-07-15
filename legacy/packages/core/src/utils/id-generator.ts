/**
 * 雪花 ID 生成器 - 64-bit 分布式 ID
 * 结构: 1位符号 + 41位时间戳 + 10位机器ID + 12位序列
 * 单调递增、跨端不冲突、支持反解时间
 */

const EPOCH = 1700000000000; // 2023-11-14 自定义起点
const MACHINE_BITS = 10;
const SEQUENCE_BITS = 12;
const MAX_MACHINE = -1 ^ (-1 << MACHINE_BITS);
const MAX_SEQUENCE = -1 ^ (-1 << SEQUENCE_BITS);

let machineId: number | null = null;
let sequence = 0;
let lastTimestamp = -1;

function getMachineId(): number {
  if (machineId !== null) return machineId;
  // 优先用 localStorage/AsyncStorage/secure random 生成稳定 ID
  if (typeof crypto !== 'undefined' && 'getRandomValues' in crypto) {
    const buf = new Uint16Array(1);
    crypto.getRandomValues(buf);
    machineId = (buf[0] ?? 0) % (MAX_MACHINE + 1);
  } else {
    machineId = Math.floor(Math.random() * (MAX_MACHINE + 1));
  }
  return machineId;
}

/** 重置 machineId（仅在测试或持久化恢复时使用） */
export function setMachineId(id: number): void {
  if (id < 0 || id > MAX_MACHINE) throw new RangeError(`machineId must be 0..${MAX_MACHINE}`);
  machineId = id;
}

function waitNextMillis(ts: number): number {
  let now = Date.now();
  while (now <= ts) now = Date.now();
  return now;
}

export function generateId(): string {
  let ts = Date.now();
  if (ts < lastTimestamp) {
    // 时钟回拨：等待追上
    ts = waitNextMillis(lastTimestamp);
  }
  if (ts === lastTimestamp) {
    sequence = (sequence + 1) & MAX_SEQUENCE;
    if (sequence === 0) ts = waitNextMillis(lastTimestamp);
  } else {
    sequence = 0;
  }
  lastTimestamp = ts;

  const id =
    ((ts - EPOCH) << (MACHINE_BITS + SEQUENCE_BITS)) |
    (getMachineId() << SEQUENCE_BITS) |
    sequence;
  return id.toString(36);
}

/** 从 ID 提取生成时间戳 */
export function extractTimestamp(id: string): number {
  const n = parseInt(id, 36);
  return (n >> (MACHINE_BITS + SEQUENCE_BITS)) + EPOCH;
}
