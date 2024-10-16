export enum DefiAppMerkleTypes {
  BalanceInput,
  DistroInput,
}

export type BalanceInput = {
  avgBalance: string | bigint;
  boost: string | bigint;
  protocolId: `0x${string}`;
  timeSpanId: `0x${string}`;
  userId: `0x${string}`;
};

export type DistroInput = {
  points: string | bigint;
  tokens: string | bigint;
  userId: `0x${string}`;
};
