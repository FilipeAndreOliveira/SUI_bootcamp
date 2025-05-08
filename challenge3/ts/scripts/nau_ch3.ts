// scripts/nau_ch3.ts
// ---------------------------------------------------------------
//  Challenge-3 helpers for the NAU package
//  (run with:  npx tsx scripts/nau_ch3.ts <command>)
// ---------------------------------------------------------------
import 'dotenv/config';
import {
  SuiClient,
  getFullnodeUrl,
  SuiObjectChange,
  SuiObjectResponse,
} from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import { fromBase64, normalizeSuiAddress } from '@mysten/sui/utils';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';

import {
  PRIVATE_KEY,
  PACKAGE_ID,
  EXCHANGE_ID,
  STAKE_POOL_ID,
  COIN_TYPE,
} from './constants';

// ---------------------------------------------------------------
//  Boiler-plate: RPC client + keypair
// ---------------------------------------------------------------
const client = new SuiClient({ url: getFullnodeUrl('devnet') });

const raw = fromBase64(PRIVATE_KEY);
const keypair = Ed25519Keypair.fromSecretKey(raw[0] === 0 ? raw.slice(1) : raw);

const myAddress = normalizeSuiAddress(keypair.toSuiAddress());
console.log('Using', myAddress);

// ---------------------------------------------------------------
//  1. Swap any amount of SUI → NAU and send the NAU to the caller
//     `mistAmount` is in MIST (1 SUI = 1_000_000_000 MIST)
// ---------------------------------------------------------------
export async function swapForNau(mistAmount: bigint) {
  const tx = new Transaction();

  // carve the exact SUI amount off the gas coin
  const suiCoin = tx.splitCoins(tx.gas, [tx.pure.u64(mistAmount)]);

  // call swap_for_nau(exchange, suiCoin)
  const nauCoin = tx.moveCall({
    target: `${PACKAGE_ID}::nau::swap_for_nau`,
    arguments: [tx.object(EXCHANGE_ID), suiCoin],
  });

  // transfer the resulting NAU coin to our address
  tx.transferObjects([nauCoin], tx.pure.address(myAddress));

  const res = await signAndRun(tx, { showObjectChanges: true });

  const newId = res.objectChanges?.find(
    (c): c is Extract<SuiObjectChange, { type: 'created' }> =>
      c.type === 'created',
  )?.objectId;

  console.log('Swapped SUI → NAU coin:', newId);
  return newId;
}

// ---------------------------------------------------------------
//  2a. Swap *and* immediately stake – single PTB
// ---------------------------------------------------------------
export async function swapAndStake(mistAmount: bigint) {
  const tx = new Transaction();

  const suiCoin = tx.splitCoins(tx.gas, [tx.pure.u64(mistAmount)]);

  const nauCoin = tx.moveCall({
    target: `${PACKAGE_ID}::nau::swap_for_nau`,
    arguments: [tx.object(EXCHANGE_ID), suiCoin],
  });

  // keep the ticket that stake_nau returns
  const ticket = tx.moveCall({
    target: `${PACKAGE_ID}::nau::stake_nau`,
    arguments: [tx.object(STAKE_POOL_ID), nauCoin],
  });

  // send the StakeTicket to your own address
  tx.transferObjects([ticket], tx.pure.address(myAddress));

  const res = await signAndRun(tx, { showEffects: true });
  console.log('swap+stake status:', res.effects?.status);
  return res;
}

// ---------------------------------------------------------------
//  2b. TWO‑STEP swap *then* stake (separate transactions)
// ---------------------------------------------------------------
export async function swapThenStakeSeparate(mistAmount: bigint) {
  // 1) swap SUI → NAU
  const nauId = await swapForNau(mistAmount);
  if (!nauId) throw new Error('Swap failed, no NAU coin id found');

  // 2) new PTB that stakes the freshly‑received NAU coin
  const tx = new Transaction();
  tx.moveCall({
    target: `${PACKAGE_ID}::nau::stake_nau`,
    arguments: [tx.object(STAKE_POOL_ID), tx.object(nauId)],
  });

  const res = await signAndRun(tx, { showEffects: true });
  console.log('Staked NAU coin:', nauId);
  return res;
}

// ---------------------------------------------------------------
//  2c. unstake quick helper, takes the stakeTicket_ID from stake
// ---------------------------------------------------------------
export async function unstake(ticketId: string) {
  const tx = new Transaction();
  const nauBack = tx.moveCall({
    target: `${PACKAGE_ID}::nau::unstake_nau`,
    arguments: [tx.object(STAKE_POOL_ID), tx.object(ticketId)],
  });
  tx.transferObjects([nauBack], tx.pure.address(myAddress));
  const res = await signAndRun(tx, { showEffects: true });
  console.log('unstake status:', res.effects?.status);
}


// ----------------------------------------------------------------
//  3. First SUI coin after faucet
// ---------------------------------------------------------------
export async function firstSuiCoin() {
  const { data } = await client.getOwnedObjects({
    owner: myAddress,
    filter: { StructType: '0x2::coin::Coin<0x2::sui::SUI>' },
    options: { showType: true },
  });
  if (!data.length) throw new Error('No SUI coins!');
  const id = data[0].data!.objectId!;
  console.log('First SUI coin id:', id);
  return id;
}

// ------------------------------------------------------------------
// 4a.v2 Split a coin into 4 equal parts and log the storage rebate
// ------------------------------------------------------------------
async function splitCoin(coinId: string) {
  const tx = new Transaction();

  // 1) current balance of the coin
  const { data } = await client.getObject({
    id: coinId,
    options: { showContent: true },
  });
  const balance: bigint = BigInt((data!.content as any).fields.balance);

  // 2) amounts vector: three quarters, parent keeps the 4th
  const quarter = balance / BigInt(4);
  //const amounts: bigint[] = [quarter, quarter, quarter];

  // 3) split call
  const [c1, c2, c3] = tx.splitCoins(
    tx.object(coinId),
    [
      tx.pure.u64(Number(quarter)),
      tx.pure.u64(Number(quarter)),
      tx.pure.u64(Number(quarter)),
    ],
  );
  
  // use the three new coins so they’re not “unused”
  tx.transferObjects([c1, c2, c3], tx.pure.address(myAddress));

  // 4) execute
  const res = await signAndRun(tx, {
    showEffects: true,
    showObjectChanges: true,
  });

  console.log('StorageCost (split TX):', res.effects?.gasUsed.storageCost);

  // 5) IDs of the three new coins
  const created = (res.objectChanges || [])
    .filter(
      (o): o is Extract<SuiObjectChange, { type: 'created' }> =>
        o.type === 'created',
    )
    .map((o) => o.objectId);
  console.log('created IDs:', created.join(', '));

  // 6) fetch each coin and add up their storage rebates
  const infos: SuiObjectResponse[] = await Promise.all(
    created.map((id) =>
      client.getObject({
        id,
        options: { showContent: false, showStorageRebate: true },
      }),
    ),
  );
  const totalRebate = infos.reduce(
    (sum, obj) => sum + BigInt(obj.data?.storageRebate ?? BigInt(0)),
    BigInt(0),
  );
  console.log('Total rebate locked in quarters:', totalRebate, 'MIST');
}

// ----------------------------------------------
//  splitOnly – split into 4 and print total rebate
// ----------------------------------------------
export async function splitOnly(coinId: string) {
  await splitCoin(coinId);   // splitCoin already logs everything you need
}

// ---------------------------------------------------------------
// 4b. splitThenMerge – split in one TX, merge in a second TX
// ---------------------------------------------------------------
export async function splitThenMerge(parentId: string) {

  // 1) SPLIT TX – create three quarter‑coins
  const splitTx = new Transaction();

  // fetch current balance of parent
  const { data } = await client.getObject({
    id: parentId,
    options: { showContent: true },
  });
  const bal = BigInt((data!.content as any).fields.balance);
  const q   = bal / BigInt(4);

  const [c1, c2, c3] = splitTx.splitCoins(
    splitTx.object(parentId),
    [splitTx.pure.u64(Number(q)),
     splitTx.pure.u64(Number(q)),
     splitTx.pure.u64(Number(q))],
  );

  // transfer the quarters to yourself so they have an owner
  splitTx.transferObjects([c1, c2, c3], splitTx.pure.address(myAddress));

  const splitRes = await signAndRun(splitTx, { showObjectChanges: true });

  // pick only the 3 Coin<SUI> objects we just minted
  const quarters = (splitRes.objectChanges || [])
    .filter(
      (o): o is Extract<SuiObjectChange, { type: 'created' }> =>
        o.type === 'created' &&
        o.objectType === '0x2::coin::Coin<0x2::sui::SUI>'
    )
    .map((o) => o.objectId);

  console.log('split → created:', quarters.join(', '));

  // 2) (optional) small delay so the indexer sees the new objects
  await new Promise((r) => setTimeout(r, 1200));   // 1.2 s

  // 3) MERGE TX – fold the quarters back into the parent
  const mergeTx = new Transaction();

  const primary = mergeTx.object(parentId);
  const sources = quarters.map((id) => mergeTx.object(id));

  mergeTx.mergeCoins(primary, sources);

  const mergeRes = await signAndRun(mergeTx, { showEffects: true });
  const g = mergeRes.effects!.gasUsed;

  console.log('\n--- merge TX gas summary ---');
  console.log('computationCost        :', g.computationCost, 'MIST');
  console.log('storageCost            :', g.storageCost, 'MIST');
  console.log('storageRebate (refund) :', g.storageRebate, 'MIST');
  console.log('nonRefundableStorageFee:', g.nonRefundableStorageFee, 'MIST');
}

// ---------------------------------------------------------------
// 5. Full challenge cycle: swap -> stake -> unstake -> burn
// ---------------------------------------------------------------
export async function fullCycle2(
  stakeTicketId: string,
  mistAmount: bigint = BigInt(1_000_000_000)     // 1 SUI default
) {
  const tx = new Transaction();

  // 1) carve SUI off the gas coin
  const suiIn = tx.splitCoins(tx.gas, [tx.pure.u64(mistAmount)]);

  // 2)  swap_for_nau  — NO typeArguments here
  const nauFromSwap = tx.moveCall({
    target: `${PACKAGE_ID}::nau::swap_for_nau`,
    arguments: [tx.object(EXCHANGE_ID), suiIn],
  });

  // 3)  unstake_nau  — NO typeArguments either
  const nauFromUnstake = tx.moveCall({
    target: `${PACKAGE_ID}::nau::unstake_nau`,
    arguments: [tx.object(STAKE_POOL_ID), tx.object(stakeTicketId)],
  });

  // 4) merge the two NAU coins
  tx.mergeCoins(nauFromUnstake, [nauFromSwap]);

  // 5)  burn_for_sui  — also without typeArguments
  const suiOut = tx.moveCall({
    target: `${PACKAGE_ID}::nau::burn_for_sui`,
    arguments: [tx.object(EXCHANGE_ID), nauFromUnstake],
  });

  // 6) send the SUI back to you
  tx.transferObjects([suiOut], tx.pure.address(myAddress));

  //----------------------------------------------------------------
  //  Execute & calculate the net SUI reward
  //----------------------------------------------------------------
  const res = await signAndRun(tx, {
    showEffects: true,
    showBalanceChanges: true,
  });

  // filter balanceChanges → how much SUI our address gained?
  const reward =
    res.balanceChanges
      ?.filter(
        (b) =>
          typeof b.owner === 'object' &&
          b.owner !== null &&
          'AddressOwner' in b.owner &&
          b.owner.AddressOwner === myAddress &&
          b.coinType === '0x2::sui::SUI'
      )
      .reduce((sum, b) => sum + BigInt(b.amount), BigInt(0)) ?? BigInt(0);

  console.log('\n=== cycle summary ===');
  console.log('net SUI reward:', `${reward} MIST`);

  return reward;
}

// ---------------------------------------------------------------
//  helper: sign & run
// ---------------------------------------------------------------
function signAndRun(
  tx: Transaction,
  opts: Parameters<typeof client.signAndExecuteTransaction>[0]['options'],
) {
  return client.signAndExecuteTransaction({
    transaction: tx,
    signer: keypair,
    options: opts,
  });
}

// ---------------------------------------------------------------
//  very light CLI – swap‑based
// ---------------------------------------------------------------
const DEFAULT_MIST = BigInt(1_000_000_000);   // 1 SUI in MIST

function parseMist(val?: string): bigint {
  if (val === undefined) return DEFAULT_MIST;
  if (!/^\d+$/.test(val)) {
    throw new Error('amount must be an integer number of MIST');
  }
  return BigInt(val);
}

(async () => {
  const [cmd, arg] = process.argv.slice(2);

  switch (cmd) {

    case 'mint': {                 // alias for swap
      const amt = parseMist(arg);
      await swapForNau(amt);
      break;
    }

    case 'mintStake': {            // alias for swapStake
      const amt = parseMist(arg);
      await swapAndStake(amt);
      break;
    }

    case 'mintStakeSeparate': {    // alias for swapStakeSeparate
      const amt = parseMist(arg);
      await swapThenStakeSeparate(amt);
      break;
    }

    // --- object‑ID commands
    case 'unstake':
      if (!arg) throw new Error('pass the StakeTicket objectId');
      await unstake(arg);
      break;

    case 'firstSui':
      await firstSuiCoin();
      break;

    case 'splitOnly':
      if (!arg) throw new Error('pass coinId');
      await splitOnly(arg);
      break;

    case 'splitThenMerge':
      if (!arg) throw new Error('pass parent coinId');
      await splitThenMerge(arg);
      break;

    case 'cycle': {
      const ticketId = arg;             // 1st arg after 'cycle'
      const mistStr  = process.argv[4]; // 2nd arg (may be undefined)
      if (!ticketId) throw new Error('pass StakeTicket objectId');
    
      const amt = parseMist(mistStr);   // defaults to 1 SUI when undefined
      await fullCycle2(ticketId, amt);
      break;
    }

    default:
      console.log(`
      Commands
        mint               [mist]   - swap SUI → NAU (default 1 SUI)
        mintStake          [mist]   - swap & stake in ONE PTB
        mintStakeSeparate  [mist]   - two-step swap then stake
        unstake   <StakeTicketId>        - unstake with your StakeTicket

        firstSui                     - print first SUI coin id
        splitOnly        <coinId>    - split SUI coin into 4, show rebate
        splitThenMerge   <coinId>    - split, show rebate, then merge
        cycle            <StakeTicketId> [mist(Optional)]    - swap + unstake + burn for SUI

      Legacy aliases: mint, mintStake, mintStakeSeparate
      `);
  }
})();

// ---------------------------------------------------------------
// Quick-test commands (Devnet)
// ---------------------------------------------------------------
//
// - MINT/SWAP — mint NAU out of thin air
//   1 SUI → NAU (default amount)            ↓
//   npx tsx scripts/nau_ch3.ts mint
//
// - MINT/SWAP + STAKE in one PTB
//   Stake 5 SUI worth of NAU                ↓
//   npx tsx scripts/nau_ch3.ts mintStake 5000000000
//
// - Two-step SWAP then STAKE (separate TXs)
//   npx tsx scripts/nau_ch3.ts mintStakeSeparate 2000000000
//
// - UNSTAKE one of your tickets
//   npx tsx scripts/nau_ch3.ts unstake <StakeTicketId>
//
// - FIRST SUI COIN (after faucet)
//   npx tsx scripts/nau_ch3.ts firstSui
//
// - SPLIT a SUI coin into quarters & show rebate
//   npx tsx scripts/nau_ch3.ts splitOnly <parentCoinId>
//
// - SPLIT *then* MERGE to see gas / rebate
//   npx tsx scripts/nau_ch3.ts splitThenMerge <parentCoinId>
//
// - FULL “cycle” PTB  ➜  swap SUI → NAU, unstake NAU, burn NAU → SUI
//   # 5 SUI input, using an existing StakeTicket
//   npx tsx scripts/nau_ch3.ts cycle <StakeTicketId> 5000000000
//   # omit the 2nd arg to default to 1 SUI
//
// ---------------------------------------------------------------

