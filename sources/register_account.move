module faucet_addr::account_registrar {

    use supra_framework::account;
    use supra_framework::supra_account;
    use supra_framework::event::{Self, EventHandle};

    const E_ACCOUNT_ALREADY_EXISTS: u64 = 1;

    struct AccountCreated has drop, store {
        new_account_address: address,
    }

    struct EventHandles has key {
        account_created_event: EventHandle<AccountCreated>,
    }

    fun init_module(sender: &signer) {
        move_to(sender, EventHandles {
            account_created_event: account::new_event_handle<AccountCreated>(sender),
        });
    }

    public entry fun register_account(_creator: &signer, new_account_address: address) acquires EventHandles {
        if (!account::exists_at(new_account_address)) {
            supra_account::create_account(new_account_address);

            let event_handles = borrow_global_mut<EventHandles>(@faucet_addr);
            event::emit_event(
                &mut event_handles.account_created_event,
                AccountCreated {
                    new_account_address
                }
            );
        }
    }
}
