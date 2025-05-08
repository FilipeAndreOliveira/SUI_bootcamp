// ts/scripts/constants.ts
//------------------------------------------------------------
//  Central place to read .env and expose typed constants
//------------------------------------------------------------
import * as dotenv from 'dotenv';
dotenv.config(); // ← loads .env into process.env

//------------------------------------------------------------
//  Raw env-vars ------------------------------------------------
export const {
  RPC_URL     = 'https://fullnode.devnet.sui.io:443', // fallback just in case
  PRIVATE_KEY,
  PACKAGE_ID,
  EXCHANGE_ID,
  ADMIN_CAP,
  STAKE_POOL_ID,
} = process.env as Record<string, string>;

// Guard-rails so we fail fast if something is missing
if (!PRIVATE_KEY) throw new Error('PRIVATE_KEY missing in .env');
if (!PACKAGE_ID)  throw new Error('PACKAGE_ID missing in .env');
if (!EXCHANGE_ID) throw new Error('EXCHANGE_ID missing in .env');
if (!ADMIN_CAP)   throw new Error('ADMIN_CAP missing in .env');
if (!STAKE_POOL_ID)   throw new Error('ADMIN_CAP missing in .env');

//------------------------------------------------------------
//  Fully-qualified type / struct strings used by the SDK ----
//  (These MUST match the names inside `contract_nau_v2::nau`)  
//------------------------------------------------------------
export const MODULE_NAME      = 'nau';
export const COIN_STRUCT      = 'NAU';
export const EXCHANGE_STRUCT  = 'NauExchange';
export const ADMIN_CAP_STRUCT = 'AdminCap';
export const STAKE_POOL_STRUCT = 'StakePool';

// e.g. 0xbb16…::nau::NAU
export const COIN_TYPE        = `${PACKAGE_ID}::${MODULE_NAME}::${COIN_STRUCT}`;

// e.g. 0xbb16…::nau::NauExchange
export const EXCHANGE_TYPE    = `${PACKAGE_ID}::${MODULE_NAME}::${EXCHANGE_STRUCT}`;

// e.g. 0xbb16…::nau::AdminCap
export const ADMIN_CAP_TYPE   = `${PACKAGE_ID}::${MODULE_NAME}::${ADMIN_CAP_STRUCT}`;

// e.g. 0xbb16…::nau::StakePool
export const STAKE_POOL_TYPE   = `${PACKAGE_ID}::${MODULE_NAME}::${STAKE_POOL_STRUCT}`;

//------------------------------------------------------------
//  Convenience numbers that match the Move contract ----------
//------------------------------------------------------------
export const FEE_BPS    = 100;           // 1 %   (basis-points)
export const PRICE_SUI  = 10_000_000_000; // 10 SUI (in MIST)
export const AMOUNT_NAU = 50_000_000_000; // 50 NAU (in “nano” units)
