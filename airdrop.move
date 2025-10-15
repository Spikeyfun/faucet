module faucet_addr::admin_faucet {
    use supra_framework::account;
    use supra_framework::coin::{Self};
    use supra_framework::event::{Self, EventHandle};
    use supra_framework::fungible_asset::{Metadata};
    use supra_framework::object::{Self, Object};
    use supra_framework::primary_fungible_store;
    use supra_framework::signer;
    use supra_framework::type_info::{Self, TypeInfo};
    use supra_framework::timestamp;
    use std::error;
    use std::bcs;
    use aptos_std::table::{Self, Table};

    // --- Constants ---
    const E_NOT_ADMIN: u64 = 1;
    const E_FAUCET_NOT_INITIALIZED: u64 = 2;
    const E_INSUFFICIENT_FUNDS: u64 = 3;
    const E_ALREADY_CLAIMED: u64 = 4;
    const E_ASSET_NOT_CONFIGURED: u64 = 5;
    const E_ZERO_DEPOSIT_NOT_ALLOWED: u64 = 6;
    const E_RATE_LIMIT_EXCEEDED: u64 = 7;
    const E_AMOUNT_BELOW_MINIMUM: u64 = 8;
    const E_INVALID_DELAY_SETTING: u64 = 9;
    const E_MAX_CLAIMS_REACHED: u64 = 10;

    const MINIMUM_CLAIM_AMOUNT: u64 = 100;
    const FAUCET_SEED: vector<u8> = b"faucet_resource";

    // --- Structs ---
    struct AdminCapability has key, store {}

    struct ModuleSignerStorage has key {
        signer_cap: account::SignerCapability,
    }

    struct FaucetStore has key {
        admin_cap: Object<AdminCapability>,
        claim_amounts: Table<TypeInfo, u64>,
        fa_claim_amounts: Table<address, u64>,
        max_claims_per_wallet: Table<vector<u8>, u64>,
        deposit_events: EventHandle<DepositEvent>,
        claim_events: EventHandle<ClaimEvent>,
        last_claim_timestamp_micros: u64,
        claim_delay_micros: u64,
    }

    struct ClaimHistory has key {
        claimed_assets: Table<vector<u8>, u64>,
    }

    // --- Events ---
    #[event]
    struct DepositEvent has drop, store {
        depositor: address,
        asset_type: vector<u8>,
        amount: u64,
    }

    #[event]
    struct ClaimEvent has drop, store {
        claimer: address,
        asset_type: vector<u8>,
        amount: u64,
    }

    // --- Functions ---
    fun init_module(deployer: &signer) {
        let (resource_account_signer, signer_cap) = account::create_resource_account(deployer, FAUCET_SEED);
        
        move_to(&resource_account_signer, ModuleSignerStorage { signer_cap });

        let constructor_ref = object::create_object_from_account(deployer);
        let object_signer = object::generate_signer(&constructor_ref); 
        move_to(&object_signer, AdminCapability {});
        let admin_cap_obj = object::object_from_constructor_ref<AdminCapability>(&constructor_ref);

        move_to(&resource_account_signer, FaucetStore {
            admin_cap: admin_cap_obj,
            claim_amounts: table::new(),
            fa_claim_amounts: table::new(),
            max_claims_per_wallet: table::new(),
            deposit_events: account::new_event_handle<DepositEvent>(&resource_account_signer),
            claim_events: account::new_event_handle<ClaimEvent>(&resource_account_signer),
            last_claim_timestamp_micros: 0,
            claim_delay_micros: 1_000_000, 
        });
    }

    fun assert_is_admin(addr: address) acquires FaucetStore {
        let resource_addr = get_resource_account_address(); 
        assert!(exists<FaucetStore>(resource_addr), error::not_found(E_FAUCET_NOT_INITIALIZED));
        let store = borrow_global<FaucetStore>(resource_addr); 
        let admin_cap_owner = object::owner(store.admin_cap);
        assert!(addr == admin_cap_owner, error::permission_denied(E_NOT_ADMIN));
    }

    fun get_resource_signer(): signer acquires ModuleSignerStorage {
        let resource_addr = get_resource_account_address(); 
        let signer_cap = &borrow_global<ModuleSignerStorage>(resource_addr).signer_cap;
        account::create_signer_with_capability(signer_cap)
    }

    // --- Entry Functions ---
    public entry fun set_claim_delay(admin: &signer, new_delay_micros: u64) acquires FaucetStore {
        let addr = signer::address_of(admin);
        assert_is_admin(addr);
        assert!(new_delay_micros >= 100_000, error::invalid_argument(E_INVALID_DELAY_SETTING));
        let resource_addr = get_resource_account_address();
        let store = borrow_global_mut<FaucetStore>(resource_addr); 
        store.claim_delay_micros = new_delay_micros;
    }

    public entry fun set_max_claims<AssetType>(admin: &signer, max_claims: u64) acquires FaucetStore {
        let addr = signer::address_of(admin);
        assert_is_admin(addr);
        let resource_addr = get_resource_account_address(); 
        let store = borrow_global_mut<FaucetStore>(resource_addr); 
        let asset_key = bcs::to_bytes(&type_info::type_of<AssetType>());
        table::upsert(&mut store.max_claims_per_wallet, asset_key, max_claims);
    }

    public entry fun set_coin_claim_amount<CoinType>(admin: &signer, amount: u64) acquires FaucetStore {
        let addr = signer::address_of(admin);
        assert_is_admin(addr);
        assert!(amount >= MINIMUM_CLAIM_AMOUNT, error::invalid_argument(E_AMOUNT_BELOW_MINIMUM));
        let resource_addr = get_resource_account_address(); 
        let store = borrow_global_mut<FaucetStore>(resource_addr); 
        let type_info = type_info::type_of<CoinType>();
        table::upsert(&mut store.claim_amounts, type_info, amount);
    }

    public entry fun set_fa_claim_amount(admin: &signer, metadata_addr: address, amount: u64) acquires FaucetStore {
        let addr = signer::address_of(admin);
        assert_is_admin(addr);
        assert!(amount >= MINIMUM_CLAIM_AMOUNT, error::invalid_argument(E_AMOUNT_BELOW_MINIMUM));
        let resource_addr = get_resource_account_address(); 
        let store = borrow_global_mut<FaucetStore>(resource_addr);
        table::upsert(&mut store.fa_claim_amounts, metadata_addr, amount);
    }

    public entry fun deposit_coin<CoinType>(account: &signer, amount: u64) acquires FaucetStore, ModuleSignerStorage {
        assert!(amount > 0, error::invalid_argument(E_ZERO_DEPOSIT_NOT_ALLOWED));
        let resource_addr = get_resource_account_address(); 
        let store = borrow_global_mut<FaucetStore>(resource_addr); 
        let type_info = type_info::type_of<CoinType>();
        assert!(table::contains(&store.claim_amounts, type_info), error::not_found(E_ASSET_NOT_CONFIGURED));
        let resource_signer = get_resource_signer();
        let resource_addr = signer::address_of(&resource_signer);
        if (!coin::is_account_registered<CoinType>(resource_addr)) {
            coin::register<CoinType>(&resource_signer);
        };
        let coin = coin::withdraw<CoinType>(account, amount);
        coin::deposit(resource_addr, coin);
        event::emit_event(&mut store.deposit_events, DepositEvent {
            depositor: signer::address_of(account),
            asset_type: bcs::to_bytes(&type_info),
            amount,
        });
    }

    public entry fun deposit_fungible_asset(account: &signer, metadata_addr: address, amount: u64) acquires FaucetStore, ModuleSignerStorage {
        assert!(amount > 0, error::invalid_argument(E_ZERO_DEPOSIT_NOT_ALLOWED));
        let resource_addr = get_resource_account_address(); 
        let store = borrow_global_mut<FaucetStore>(resource_addr); 
        assert!(table::contains(&store.fa_claim_amounts, metadata_addr), error::not_found(E_ASSET_NOT_CONFIGURED));
        let metadata: Object<Metadata> = object::address_to_object<Metadata>(metadata_addr);
        let resource_signer = get_resource_signer();
        let resource_addr = signer::address_of(&resource_signer);
        let fa = primary_fungible_store::withdraw(account, metadata, amount);
        if (!primary_fungible_store::primary_store_exists(resource_addr, metadata)) {
            primary_fungible_store::create_primary_store(resource_addr, metadata);
        };
        primary_fungible_store::deposit(resource_addr, fa);
        event::emit_event(&mut store.deposit_events, DepositEvent {
            depositor: signer::address_of(account),
            asset_type: bcs::to_bytes(&metadata_addr),
            amount,
        });
    }

    public entry fun claim_coin<CoinType>(user: &signer) acquires FaucetStore, ModuleSignerStorage, ClaimHistory {
        let user_addr = signer::address_of(user);
        let resource_addr = get_resource_account_address(); 
        let store = borrow_global_mut<FaucetStore>(resource_addr); 
        let current_time_micros = timestamp::now_microseconds();
        let delay_micros = store.claim_delay_micros;
        assert!(current_time_micros >= store.last_claim_timestamp_micros + delay_micros, error::aborted(E_RATE_LIMIT_EXCEEDED));
        store.last_claim_timestamp_micros = current_time_micros;
        if (!exists<ClaimHistory>(user_addr)) {
            move_to(user, ClaimHistory { claimed_assets: table::new() });
        };
        let type_info = type_info::type_of<CoinType>();
        let asset_key = bcs::to_bytes(&type_info);
        let claim_history = borrow_global_mut<ClaimHistory>(user_addr);
        let claims_done = if (table::contains(&claim_history.claimed_assets, asset_key)) {
            *table::borrow(&claim_history.claimed_assets, asset_key)
        } else {
            0
        };
        let max_claims = if (table::contains(&store.max_claims_per_wallet, asset_key)) {
            *table::borrow(&store.max_claims_per_wallet, asset_key)
        } else {
            1
        };
        assert!(claims_done < max_claims, error::permission_denied(E_MAX_CLAIMS_REACHED));
        assert!(table::contains(&store.claim_amounts, type_info), error::not_found(E_ASSET_NOT_CONFIGURED));
        let claim_amount = *table::borrow(&store.claim_amounts, type_info);
        let resource_signer = get_resource_signer();
        let resource_addr = signer::address_of(&resource_signer);
        assert!(coin::balance<CoinType>(resource_addr) >= claim_amount, error::invalid_state(E_INSUFFICIENT_FUNDS));
        let claimed_coin = coin::withdraw<CoinType>(&resource_signer, claim_amount);
        coin::deposit(user_addr, claimed_coin);
        table::upsert(&mut claim_history.claimed_assets, asset_key, claims_done + 1);
        event::emit_event(&mut store.claim_events, ClaimEvent {
            claimer: user_addr,
            asset_type: asset_key,
            amount: claim_amount,
        });
    }

    public entry fun claim_fungible_asset(user: &signer, metadata_addr: address) acquires FaucetStore, ModuleSignerStorage, ClaimHistory {
        let user_addr = signer::address_of(user);
        let resource_addr = get_resource_account_address(); 
        let store = borrow_global_mut<FaucetStore>(resource_addr); 
        let current_time_micros = timestamp::now_microseconds();
        let delay_micros = store.claim_delay_micros;
        assert!(current_time_micros >= store.last_claim_timestamp_micros + delay_micros, error::aborted(E_RATE_LIMIT_EXCEEDED));
        store.last_claim_timestamp_micros = current_time_micros;
        if (!exists<ClaimHistory>(user_addr)) {
            move_to(user, ClaimHistory { claimed_assets: table::new() });
        };
        let asset_key = bcs::to_bytes(&metadata_addr);
        let claim_history = borrow_global_mut<ClaimHistory>(user_addr);
        let claims_done = if (table::contains(&claim_history.claimed_assets, asset_key)) {
            *table::borrow(&claim_history.claimed_assets, asset_key)
        } else {
            0
        };
        let max_claims = if (table::contains(&store.max_claims_per_wallet, asset_key)) {
            *table::borrow(&store.max_claims_per_wallet, asset_key)
        } else {
            1
        };
        assert!(claims_done < max_claims, error::permission_denied(E_MAX_CLAIMS_REACHED));
        assert!(table::contains(&store.fa_claim_amounts, metadata_addr), error::not_found(E_ASSET_NOT_CONFIGURED));
        let claim_amount = *table::borrow(&store.fa_claim_amounts, metadata_addr);
        let metadata = object::address_to_object<Metadata>(metadata_addr);
        let resource_signer = get_resource_signer();
        let resource_addr = signer::address_of(&resource_signer);
        assert!(primary_fungible_store::balance(resource_addr, metadata) >= claim_amount, error::invalid_state(E_INSUFFICIENT_FUNDS));
        primary_fungible_store::transfer(&resource_signer, metadata, user_addr, claim_amount);
        table::upsert(&mut claim_history.claimed_assets, asset_key, claims_done + 1);
        event::emit_event(&mut store.claim_events, ClaimEvent {
            claimer: user_addr,
            asset_type: asset_key,
            amount: claim_amount,
        });
    }

    // --- View Functions ---
    #[view]
    public fun get_resource_account_address(): address {
        account::create_resource_address(&@faucet_addr, FAUCET_SEED)
    }

    #[view]
    public fun get_faucet_coin_balance<CoinType>(): u64 {
        let resource_addr = get_resource_account_address();
        if (coin::is_account_registered<CoinType>(resource_addr)) {
            coin::balance<CoinType>(resource_addr)
        } else {
            0
        }
    }

    #[view]
    public fun get_faucet_fa_balance(metadata_addr: address): u64 {
        let resource_addr = get_resource_account_address();
        let metadata: Object<Metadata> = object::address_to_object<Metadata>(metadata_addr);
        if (primary_fungible_store::primary_store_exists(resource_addr, metadata)) {
            primary_fungible_store::balance(resource_addr, metadata)
        } else {
            0
        }
    }

    #[view]
    public fun get_claim_delay_micros(): u64 acquires FaucetStore {
        let resource_addr = get_resource_account_address();
        borrow_global<FaucetStore>(resource_addr).claim_delay_micros 
    }

    #[view]
    public fun get_coin_claim_amount<CoinType>(): u64 acquires FaucetStore {
        let resource_addr = get_resource_account_address(); 
        let store = borrow_global<FaucetStore>(resource_addr);
        let type_info = type_info::type_of<CoinType>();
        if (table::contains(&store.claim_amounts, type_info)) {
            *table::borrow(&store.claim_amounts, type_info)
        } else {
            0
        }
    }

    #[view]
    public fun get_fa_claim_amount(metadata_addr: address): u64 acquires FaucetStore {
        let resource_addr = get_resource_account_address(); 
        let store = borrow_global<FaucetStore>(resource_addr);
        if (table::contains(&store.fa_claim_amounts, metadata_addr)) {
            *table::borrow(&store.fa_claim_amounts, metadata_addr)
        } else {
            0
        }
    }

    #[view]
    public fun get_max_claims_per_wallet<AssetType>(): u64 acquires FaucetStore {
        let resource_addr = get_resource_account_address(); 
        let store = borrow_global<FaucetStore>(resource_addr); 
        let asset_key = bcs::to_bytes(&type_info::type_of<AssetType>());
        if (table::contains(&store.max_claims_per_wallet, asset_key)) {
            *table::borrow(&store.max_claims_per_wallet, asset_key)
        } else {
            1
        }
    }

    #[view]
    public fun get_user_claim_count<AssetType>(user_addr: address): u64 acquires ClaimHistory {
        if (!exists<ClaimHistory>(user_addr)) {
            return 0
        };
        let claim_history = borrow_global<ClaimHistory>(user_addr);
        let asset_key = bcs::to_bytes(&type_info::type_of<AssetType>());
        if (table::contains(&claim_history.claimed_assets, asset_key)) {
            *table::borrow(&claim_history.claimed_assets, asset_key)
        } else {
            0
        }
    }
}