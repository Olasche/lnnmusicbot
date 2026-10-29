import 'reflect-metadata';
import {describe, expect, it, vi} from 'vitest';

vi.mock('../src/services/player.js', () => ({
  default: class {},
  STATUS: {PLAYING: 0, PAUSED: 1, IDLE: 2},
}));

import {
  decide,
  formatHeartbeat,
  formatRoster,
  priorityOf,
  readStatusMessages,
  TIMEOUT_SECONDS,
  type FailoverView,
  type Heartbeat,
  type Instance,
  type Role,
} from '../src/services/failover.js';
import PlayerManager from '../src/managers/player.js';

const first: Instance = {id: 'id-first', name: 'PC-A'};
const second: Instance = {id: 'id-second', name: 'PC-B'};
const third: Instance = {id: 'id-third', name: 'PC-C'};
const roster = [first, second, third];

const view = (heartbeat?: Partial<Heartbeat> & Instance, ageSeconds = 5): FailoverView => ({
  roster,
  heartbeat: heartbeat ? {state: 'active', busy: false, ...heartbeat} : undefined,
  heartbeatAgeSeconds: heartbeat ? ageSeconds : Number.POSITIVE_INFINITY,
});

describe('failover priority', () => {
  it('ranks by roster order and puts unknown installs last', () => {
    expect(priorityOf(roster, first.id)).toBe(0);
    expect(priorityOf(roster, third.id)).toBe(2);
    expect(priorityOf(roster, 'not-registered')).toBe(Number.POSITIVE_INFINITY);
  });
});

describe('failover decisions', () => {
  it.each<[string, Role, Instance, FailoverView, ReturnType<typeof decide>]>([
    // Standby
    ['claims when nobody has ever been active', 'standby', second, view(), 'claim'],
    ['claims when the active heartbeat is stale', 'standby', second, view(first, TIMEOUT_SECONDS), 'claim'],
    ['claims right away when the active install stopped cleanly', 'standby', second, view({...first, state: 'stopped'}), 'claim'],
    ['reclaims its own fresh heartbeat after a restart', 'standby', first, view(first), 'claim'],
    ['waits while a higher install is active', 'standby', second, view(first), 'wait'],
    ['waits while a higher install is claiming', 'standby', second, view({...first, state: 'claiming'}), 'wait'],
    ['waits for a lower install to finish playing before taking back', 'standby', first, view({...second, busy: true}), 'wait'],
    ['takes back from an idle lower install', 'standby', first, view(second), 'claim'],
    ['overrides a lower install that is only claiming', 'standby', first, view({...second, state: 'claiming'}), 'claim'],
    ['treats unregistered installs as lowest priority', 'standby', third, view({id: 'stranger', name: 'X'}), 'claim'],
    // Active
    ['keeps beating over its own heartbeat', 'active', first, view(first), 'beat'],
    ['keeps beating when the message is missing', 'active', first, view(), 'beat'],
    ['keeps beating over a stale heartbeat from someone else', 'active', second, view(first, TIMEOUT_SECONDS + 1), 'beat'],
    ['overrides a lower install that wrongly claimed', 'active', first, view({...second, state: 'claiming'}), 'beat'],
    ['steps down when a higher install claims', 'active', second, view({...first, state: 'claiming'}), 'step-down'],
    ['steps down when a higher install is active', 'active', second, view(first), 'step-down'],
    ['steps down when a lower install took over while it was unreachable', 'active', first, view(second), 'step-down'],
  ])('%s', (_name, role, self, failoverView, expected) => {
    expect(decide(role, self, failoverView)).toBe(expected);
  });
});

describe('status messages', () => {
  const botId = 'bot-id';
  const message = (id: string, content: string, edited: string | null = null, author = botId) => ({
    id,
    content,
    timestamp: '2026-10-29T10:00:00.000Z',
    edited_timestamp: edited,
    author: {id: author},
  });

  it('round-trips the roster and heartbeat and measures age on Discord\'s clock', () => {
    const heartbeat: Heartbeat = {...second, state: 'active', busy: true};
    const status = readStatusMessages([
      message('1002', formatHeartbeat(heartbeat), '2026-10-29T10:05:00.000Z'),
      message('1001', formatRoster(roster)),
    ], botId, Date.parse('2026-10-29T10:05:30.000Z'));

    expect(status.roster).toEqual({id: '1001', data: {instances: roster}});
    expect(status.heartbeat).toEqual({id: '1002', data: heartbeat});
    expect(status.heartbeatAgeSeconds).toBe(30);
    expect(status.duplicates).toEqual([]);
  });

  it('keeps the oldest copy of each message and reports the rest as duplicates', () => {
    const status = readStatusMessages([
      message('10000', formatRoster([first, second])),
      message('9999', formatRoster([first])),
      message('10001', formatHeartbeat({...first, state: 'active', busy: false})),
      message('10002', formatHeartbeat({...second, state: 'claiming', busy: false})),
    ], botId, Date.now());

    expect(status.roster?.id).toBe('9999');
    expect(status.heartbeat?.data.id).toBe(first.id);
    expect(status.duplicates.sort()).toEqual(['10000', '10002']);
  });

  it('ignores other authors and messages without status JSON', () => {
    const status = readStatusMessages([
      message('1', formatRoster(roster), null, 'someone-else'),
      message('2', 'hello'),
      message('3', '```json\nnot json\n```'),
    ], botId, Date.now());

    expect(status.roster).toBeUndefined();
    expect(status.heartbeat).toBeUndefined();
    expect(status.heartbeatAgeSeconds).toBe(Number.POSITIVE_INFINITY);
  });
});

describe('PlayerManager.isBusy', () => {
  const managerWith = (...players: Array<{status: number; current: unknown}>) => {
    const manager = new PlayerManager({} as never, {} as never, {} as never);
    const guildPlayers = (manager as unknown as {guildPlayers: Map<string, unknown>}).guildPlayers;
    players.forEach((player, index) => {
      guildPlayers.set(`guild-${index}`, {status: player.status, getCurrent: () => player.current});
    });
    return manager;
  };

  it('is busy while playing or paused with a song loaded, idle otherwise', () => {
    expect(managerWith().isBusy()).toBe(false);
    expect(managerWith({status: 0, current: {}}).isBusy()).toBe(true);
    expect(managerWith({status: 1, current: {}}).isBusy()).toBe(true);
    expect(managerWith({status: 1, current: null}).isBusy()).toBe(false);
    expect(managerWith({status: 2, current: null}, {status: 0, current: {}}).isBusy()).toBe(true);
  });
});
