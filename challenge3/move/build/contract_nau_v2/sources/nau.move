module contract_nau_v2::nau;

    use sui::coin::{Self, Coin, TreasuryCap, burn, mint};
    use sui::balance;
    use sui::sui::SUI;
    use sui::url;
    use std::ascii;

    /// 1) Declare your coin struct.
    ///    "has drop" means it can be dropped without special restrictions.
    public struct NAU has drop {}

    /// This struct will store:
    /// - A TreasuryCap to mint/burn NAU.
    /// - A balance of SUI to hold fees collected.
    /// - Constants for the price & fee rate.
    public struct NauExchange has key, store {
        id: UID,
        treasury_cap: TreasuryCap<NAU>,
        fee_vault: balance::Balance<SUI>,  // Accumulates fees in SUI
        liquidity_pool: balance::Balance<SUI>,// SUI reserved for NAU redemption

        // We fix a price and an amount for 1 swap cycle:
        // If the user pays `price_in_sui`, they receive `amount_of_nau` NAU.
        price_in_sui: u64,
        amount_of_nau: u64,

        // Fee as a percentage in "basis points" (e.g. 100 = 1%)
        fee_bps: u64,
    }

    public struct AdminCap has key, store {
        id: UID,
        owner: address,
    }

    // --- Error codes ---
    const EWrongAmountOfSui: u64 = 0;
    const ENotEnoughSuiInLiquidityPool: u64 = 1;
    const EZeroValueNotAllowed: u64 = 2;
    const ENotAdmin: u64 = 3;


    //--------------------------------------------------------------------
    //  INIT FUNCTION
    //--------------------------------------------------------------------
    /// Initialize the coin's metadata and create a shared NauExchange object.
    /// This function should be called once to set up your NAU coin.
    fun init(otw: NAU, ctx: &mut TxContext) {
        // 1) Choose your coin's metadata
        let decimals: u8 = 9;
        let symbol: vector<u8> = b"NAU";
        let name: vector<u8> = b"NAU";
        let description: vector<u8> = b"Portuguese sailing ship used to trade gold";
        let icon_url = url::new_unsafe(ascii::string(b"https://goldtrade.com/nau.png")); //fake url

        // 2) Create the coin type on-chain
        let (tcap, metadata) = coin::create_currency<NAU>(
            otw,
            decimals,
            symbol,
            name,
            description,
            option::some(icon_url),
            ctx
        );

        // 3) Freeze the metadata so it can't be changed
        transfer::public_freeze_object(metadata);

        // 4) Create your exchange object with a fixed price, minted amount, and fee
        let exchange = NauExchange {
            id: object::new(ctx),
            treasury_cap: tcap,
            fee_vault: balance::zero<SUI>(),   // start with zero SUI
            liquidity_pool: balance::zero<SUI>(),// start with zero SUI in the liquidity pool
            price_in_sui: 10_000_000_000,      // How much SUI someone must pay (or receive) in a swap.
            amount_of_nau: 50_000_000_000,     // How much NAU someone receives (or must pay) for that amount of SUI.
            fee_bps: 100,                      // 100 = 1% fee
        };

        // 5) Create an AdminCap object so we can claim fees later
        let admin_cap = AdminCap {
            id: object::new(ctx),
            owner: ctx.sender()
        };


        // 6) Make the exchange object shared so anyone can swap
        transfer::public_share_object(exchange);

        // Keep the tcap inside the exchange because:
        // Users would need the admin’s intervention (or some off-chain process) to perform minting or burning, rather than the contract logic doing it autonomously.
        //transfer::public_transfer(tcap, ctx.sender());

        // 7) Transfer the AdminCap to the sender (the “coin creator”)
        transfer::public_transfer(admin_cap, ctx.sender());

        // 8) Public Stake Pool adition for week 3 challenge
        init_stake_pool(ctx);
    }

    //--------------------------------------------------------------------
    //  MINT & BURN (direct calls)
    //--------------------------------------------------------------------
    /// Mint new NAU. Requires the treasury cap.
    public fun mint_nau(tcap: &mut TreasuryCap<NAU>, amount: u64, ctx: &mut TxContext): Coin<NAU> {
        // If you want to disallow zero, you can assert:
        assert!(amount > 0, EZeroValueNotAllowed);
        mint(tcap, amount, ctx)
    }

    /// Burn NAU. Requires the treasury cap.
    public fun burn_nau(tcap: &mut TreasuryCap<NAU>, nau_coin: Coin<NAU>) {
        burn(tcap, nau_coin);
    }

    /// Admin deposits SUI into the liquidity pool to fund future NAU redemptions.
    public fun admin_deposit_liquidity(
        exchange: &mut NauExchange,
        admin: &AdminCap,
        sui_coin: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        // Check that the sender matches the stored admin owner
        assert!(ctx.sender() == admin.owner, ENotAdmin);
        
        // Add the incoming SUI coin's balance into the liquidity pool.
        exchange.liquidity_pool.join(sui_coin.into_balance());
    }

    //  SWAP FUNCTION: SUI -> NAU (Arbitrary SUI amount)
    /// The user sends any amount of SUI. The contract applies a fee, and then mints
    /// NAU in proportion to the effective SUI amount at a constant rate.
    /// The rate is defined by:
    ///     rate = amount_of_nau / price_in_sui
    public fun swap_for_nau(
    exchange: &mut NauExchange,
    mut sui_in: Coin<SUI>,
    ctx: &mut TxContext
    ): Coin<NAU> {
        let input_sui = coin::value(&sui_in);
        assert!(input_sui > 0, EZeroValueNotAllowed);

        let fee = input_sui * exchange.fee_bps / 10000;
        let user_portion = input_sui - fee;
        assert!(user_portion > 0, EWrongAmountOfSui);

        let fee_balance = coin::split(&mut sui_in, fee, ctx);
        exchange.fee_vault.join(fee_balance.into_balance());

        let leftover_balance = coin::into_balance(sui_in);
        exchange.liquidity_pool.join(leftover_balance);

        // Instead of multiplying first, do division first.
        let ratio = exchange.amount_of_nau / exchange.price_in_sui; // should be 5
        let total_nau = user_portion * ratio;
        mint(&mut exchange.treasury_cap, total_nau, ctx)
    }

    //--------------------------------------------------------------------
    //  BURN-FOR-SUI FUNCTION: NAU -> SUI (Arbitrary NAU amount)
    //--------------------------------------------------------------------
    /// The user sends any amount of NAU. The contract calculates a gross SUI payout
    /// based on the constant rate (price_in_sui / amount_of_nau), deducts a fee,
    /// burnsthe NAU, and returns the net SUI to the user.
    public fun burn_for_sui(
    exchange: &mut NauExchange,
    nau_in: Coin<NAU>,
    ctx: &mut TxContext
    ): Coin<SUI> {
        let input_nau = coin::value(&nau_in);
        assert!(input_nau > 0, EZeroValueNotAllowed);
        assert!(exchange.amount_of_nau > 0, EWrongAmountOfSui);

        // Instead of multiplying first, perform division:   
        // We want gross_sui = input_nau * (price_in_sui / amount_of_nau)
        // Rearranged: gross_sui = input_nau / (amount_of_nau / price_in_sui)
        let divisor = exchange.amount_of_nau / exchange.price_in_sui;  // 50e9 / 10e9 = 5
        let gross_sui = input_nau / divisor;

        let fee = gross_sui * exchange.fee_bps / 10000;
        let net_sui = gross_sui - fee;

        assert!(exchange.liquidity_pool.value() >= gross_sui, ENotEnoughSuiInLiquidityPool);

        burn(&mut exchange.treasury_cap, nau_in);

        let mut total_sui_balance = exchange.liquidity_pool.split(gross_sui);
        let net_sui_balance = balance::split(&mut total_sui_balance, net_sui);
        exchange.fee_vault.join(total_sui_balance);

        coin::from_balance(net_sui_balance, ctx)
    }

    //--------------------------------------------------------------------
    //  CLAIM FEES
    //--------------------------------------------------------------------
    /// Admin can withdraw SUI fees that accumulated in `fee_vault`.
    public fun claim_fees(
        exchange: &mut NauExchange,
        admin: &AdminCap,
        ctx: &mut TxContext
    ): Coin<SUI> {
        // Enforce that only the admin (as specified in AdminCap) can claim fees.
        assert!(ctx.sender() == admin.owner, ENotAdmin);

        let total_fees = exchange.fee_vault.value();
        let fees_coin = exchange.fee_vault.split(total_fees);
        fees_coin.into_coin(ctx)
    }

    //--------------------------------------------------------------------
    //  TEST-ONLY HELPER
    //--------------------------------------------------------------------
    /// Test-only helper to initialize. This matches the pattern you saw in class.
    #[test_only]
    public fun init_testing(ctx: &mut TxContext) {
        // Because `init` expects an `otw: NAU`, we first create a fresh NAU object:
        let nau_obj = NAU {};
        init(nau_obj, ctx);
    }

    #[test_only]
    public fun new_admin_cap_for_testing(owner: address, ctx: &mut TxContext): AdminCap {
        AdminCap {
            id: object::new(ctx),
            owner
        }
    }

    #[test_only]
    public fun test_mint_nau_from_exchange(exchange: &mut NauExchange, amount: u64, ctx: &mut TxContext): Coin<NAU> {
        // This function is inside the same module, so it can access treasury_cap.
        mint_nau(&mut exchange.treasury_cap, amount, ctx)
    }


    // Some more stuff to help with this week's challenge:
    //------------------------------------------------------------
    //  NEW -- Staking pool structs
    //------------------------------------------------------------
    /// Shared vault that passively accumulates every user’s stake
    public struct NauStakePool has key, store {
        id: UID,
        nau_vault: balance::Balance<NAU>,
    }

    /// Receipt returned to the staker.  Destroy it to withdraw.
    public struct StakeTicket has key, store {
        id: UID,
        amount: u64,
        owner: address,
    }

    /// Extra error code
    const ENotTicketOwner: u64 = 4;

    //------------------------------------------------------------
    //  INIT helper – publish the shared pool once
    //------------------------------------------------------------
    fun init_stake_pool(ctx: &mut TxContext) {
        let pool = NauStakePool {
            id: object::new(ctx),
            nau_vault: balance::zero<NAU>(),
        };
        transfer::public_share_object(pool);
    }
    
    //------------------------------------------------------------
    //  STAKE — anybody can lock NAU and get a ticket back
    //------------------------------------------------------------
    public fun stake_nau(
        pool:   &mut NauStakePool,
        nau_in: Coin<NAU>,
        ctx:    &mut TxContext
    ): StakeTicket {
        let amount = coin::value(&nau_in);
        assert!(amount > 0, EZeroValueNotAllowed);

        // move the NAU into the shared vault
        let bal     = coin::into_balance(nau_in);
        pool.nau_vault.join(bal);

        // mint receipt for the staker
        StakeTicket {
            id:     object::new(ctx),
            amount,
            owner:  ctx.sender(),
        }
    }

    //--------------------------------------------------------------------
    //  UNSTAKE – burn the ticket and withdraw the same amount
    //--------------------------------------------------------------------
    public fun unstake_nau(
        pool:   &mut NauStakePool,
        ticket: StakeTicket,
        ctx:    &mut TxContext
    ): Coin<NAU> {
        // move-out all fields in a single pattern match ----------------
        let StakeTicket { id, owner, amount } = ticket;

        // only the ticket owner may unstake
        assert!(owner == ctx.sender(), ENotTicketOwner);

        // take NAU out of the pool
        let bal  = pool.nau_vault.split(amount);
        let coin = coin::from_balance(bal, ctx);

        // destroy the ticket object (now just its UID)
        object::delete(id);

        coin
    }


    //------------------------------------------------------------
    //  TEST-ONLY helpers (optional)
    //------------------------------------------------------------
    #[test_only]
    public fun init_stake_pool_testing(ctx: &mut TxContext) {
        init_stake_pool(ctx);
    }
