#[test_only]
module contract_nau_v2::contract_nau_tests_v2;

use sui::coin;
use sui::sui::SUI;
use sui::test_scenario as ts;
//use contract_nau_v2::nau as nau;
use contract_nau_v2::nau::{
    //NAU,
    //AdminCap,
    NauExchange,
    EZeroValueNotAllowed,
    ENotAdmin,
    ENotEnoughSuiInLiquidityPool,
    init_testing,
    new_admin_cap_for_testing,
    swap_for_nau,
    burn_for_sui,
    claim_fees,
    test_mint_nau_from_exchange
};

// ... test code follows ...
const USER: address = @0xCAFE;

    #[test]
    public fun test_swap_for_nau() {
        // Start a test scenario with USER as the sender.
        let mut scenario = ts::begin(USER);
        {
            // Initialize the NAU currency and the exchange object.
            init_testing(scenario.ctx());
        };

        // Next transaction: perform a swap.
        scenario.next_tx(USER);
        {
            // Take the shared exchange object so we can modify it.
            let mut exchange = scenario.take_shared<NauExchange>();

            // For testing, mint some SUI for the user. 
            // (1 SUI = 1e9 minimal units; adjust as per SUI's standard if needed.)
            // In our constants, price_in_sui is 10_000_000_000.
            // For example, let the user swap 20_000_000_000 SUI.
            let input_sui = 20_000_000_000;
            let sui_for_swap = coin::mint_for_testing<SUI>(input_sui, scenario.ctx());

            // Call the swap function.
            let nau_received = swap_for_nau(&mut exchange, sui_for_swap, scenario.ctx());
            
            // Expected arithmetic:
            // fee = input_sui * fee_bps/10000 = 20_000_000_000 * 100 / 10000 = 200_000_000.
            // user_portion = input_sui - fee = 20_000_000_000 - 200_000_000 = 19_800_000_000.
            // Minted NAU = user_portion * amount_of_nau / price_in_sui.
            // Since amount_of_nau is 50_000_000_000 and price_in_sui is 10_000_000_000,
            // then minted NAU = 19_800_000_000 * (50_000_000_000 / 10_000_000_000)
            //                 = 19_800_000_000 * 5 = 99_000_000_000.
            let expected_nau: u64 = 99_000_000_000;
            assert!(coin::value(&nau_received) == expected_nau, 100);
            
            // Transfer resource out of scope so there's no leftover
            transfer::public_transfer(nau_received, USER);

            ts::return_shared(exchange);
        };
        scenario.end();
    }

    #[test]
    public fun test_burn_for_sui() {
        let mut scenario = ts::begin(USER);
        {
            // Initialize the contract state.
            init_testing(scenario.ctx());
        };

        scenario.next_tx(USER);
        {
            let mut exchange = scenario.take_shared<NauExchange>();

            // First, perform a swap to obtain some NAU and fund the liquidity pool.
            let input_sui = 20_000_000_000;
            let sui_for_swap = coin::mint_for_testing<SUI>(input_sui, scenario.ctx());
            let nau_received = swap_for_nau(&mut exchange, sui_for_swap, scenario.ctx());
            // After swap, as computed before:
            // - Minted NAU = 99_000_000_000.
            // - The liquidity pool now holds user_portion = 19_800_000_000 SUI.
            // (And the fee vault now holds 200_000_000 SUI.)

            // Now, test burning NAU for SUI.
            // Use the NAU we just obtained. 
            // Calculation for burn:
            // gross_sui = input_nau_minted * price_in_sui / amount_of_nau.
            // For input_nau = 99_000_000_000:
            // gross_sui = 99_000_000_000 * 10_000_000_000 / 50_000_000_000 
            //           = 99_000_000_000 * (10 / 50) 
            //           = 99_000_000_000 * 0.2 = 19_800_000_000.
            // fee = gross_sui * fee_bps / 10000 = 19_800_000_000 * 100 / 10000 = 198_000_000.
            // net_sui = gross_sui - fee = 19_800_000_000 - 198_000_000 = 19_602_000_000.
            
            let expected_sui: u64 = 19_602_000_000;
            let sui_received = burn_for_sui(&mut exchange, nau_received, scenario.ctx());
            assert!(coin::value(&sui_received) == expected_sui, 101);

            // === Add this line so the resource isn't left unused ===
            transfer::public_transfer(sui_received, USER);
            
            ts::return_shared(exchange);
        };
    
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code=EZeroValueNotAllowed)]
    public fun test_swap_with_zero_sui_fails() {
        let mut scenario = ts::begin(USER);
        {
            init_testing(scenario.ctx());
        };
        scenario.next_tx(USER);
        {
            let mut exchange = scenario.take_shared<NauExchange>();

            // Create a SUI coin with zero value.
            let zero_sui = coin::mint_for_testing<SUI>(0, scenario.ctx());

            // This should abort, as zero value is not allowed, but in case it doesn't,
            // we must consume the returned `Coin<NAU>`.
            let nau_received = swap_for_nau(&mut exchange, zero_sui, scenario.ctx());
            // Transfer it to the user so we don't leave it unused.
            transfer::public_transfer(nau_received, USER);

            ts::return_shared(exchange);
        };
        scenario.end();
    }

    #[test]
    public fun test_claim_fees_as_admin() {
        let mut scenario = ts::begin(USER);
        {
            // 1) Initialize the system.
            init_testing(scenario.ctx());
        };

        // 2) Perform a swap to accumulate fees.
        scenario.next_tx(USER);
        {
            let mut exchange = scenario.take_shared<NauExchange>();
            let input_sui: u64 = 20_000_000_000;
            let sui_for_swap = coin::mint_for_testing<SUI>(input_sui, scenario.ctx());
            
            // Capture the minted NAU and transfer it to the user.
            let minted_nau = swap_for_nau(&mut exchange, sui_for_swap, scenario.ctx());
            transfer::public_transfer(minted_nau, USER);

            ts::return_shared(exchange);
        };

        // 3) Claim the fees as admin.
        scenario.next_tx(USER);
        {
            let mut exchange = scenario.take_shared<NauExchange>();

            // Create an AdminCap resource; it must be consumed or transferred.
            let admin_cap = new_admin_cap_for_testing(USER, scenario.ctx());

            // Claim fees with the admin cap.
            let fees = claim_fees(&mut exchange, &admin_cap, scenario.ctx());
            
            // Check the fee value.
            assert!(coin::value(&fees) == 200_000_000, 102);

            // Transfer the claimed fees to the user so it's consumed.
            transfer::public_transfer(fees, USER);

            // ALSO transfer the admin_cap resource so it is not left in local scope.
            transfer::public_transfer(admin_cap, USER);

            ts::return_shared(exchange);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = ENotAdmin)]
    public fun test_claim_fees_non_admin_fails() {
        let mut scenario = ts::begin(USER);
        {
            init_testing(scenario.ctx());
        };

        // First, perform a swap to accumulate fees.
        scenario.next_tx(USER);
        {
            let mut exchange = scenario.take_shared<NauExchange>();
            let input_sui: u64 = 20_000_000_000;
            let sui_for_swap = coin::mint_for_testing<SUI>(input_sui, scenario.ctx());

            // Instead of discarding the minted coin, store it and transfer it away
            let minted_nau = swap_for_nau(&mut exchange, sui_for_swap, scenario.ctx());
            // Transfer minted NAU to the user, so the resource is fully consumed.
            transfer::public_transfer(minted_nau, USER);

            ts::return_shared(exchange);
        };

        // Now, attempt to claim fees with an invalid AdminCap.
        scenario.next_tx(USER);
        {
            let mut exchange = scenario.take_shared<NauExchange>();

            // Construct an AdminCap with the wrong owner. This resource must also be consumed.
            let wrong_admin = new_admin_cap_for_testing(@0x12345, scenario.ctx());

            // Attempt to claim fees. This should abort with ENotAdmin, but if it didn't,
            // we must handle the returned coin + the `wrong_admin` resource below.
            let fees_coin = claim_fees(&mut exchange, &wrong_admin, scenario.ctx());

            // Transfer the claimed fees coin out of local scope.
            transfer::public_transfer(fees_coin, USER);

            // Also transfer the `wrong_admin` resource somewhere (e.g. the user),
            // so we don't leave it in local scope.
            transfer::public_transfer(wrong_admin, USER);

            ts::return_shared(exchange);
        };
        scenario.end();
    }

    // -----------------------------
    // Test: Trigger ENotEnoughSuiInLiquidityPool
    // -----------------------------
    // We simulate burning NAU when the liquidity pool is empty. In our design, swap_for_nau deposits SUI
    // into the liquidity pool. If we bypass swap_for_nau—by minting NAU directly via mint_nau—the liquidity pool
    // remains empty. Then calling burn_for_sui should abort due to insufficient liquidity.
    #[test]
    #[expected_failure(abort_code = ENotEnoughSuiInLiquidityPool)]
    public fun test_burn_fails_insufficient_liquidity() {
        let mut scenario = ts::begin(USER);
        {
            init_testing(scenario.ctx());
        };

        scenario.next_tx(USER);
        {
            let mut exchange = scenario.take_shared<NauExchange>();

            // Mint NAU from exchange in a helper function, bypassing swap_for_nau
            // so that no SUI is deposited into the liquidity pool
            let nau_coin = test_mint_nau_from_exchange(&mut exchange, 50_000_000_000, scenario.ctx());

            // Attempt to burn. This will return a Coin<SUI> if it doesn't abort,
            // so we MUST handle that resource. 
            let leftover_sui = burn_for_sui(&mut exchange, nau_coin, scenario.ctx());

            // Transfer leftover_sui to the user so it's not left in local scope
            transfer::public_transfer(leftover_sui, USER);

            ts::return_shared(exchange);
        };
        scenario.end();
    }

