module riot_defi::riot_defi {

    use sui::balance::{Balance};
    use sui::coin::{Self, Coin, TreasuryCap};

    use riot_defi::coin::{LPToken};

    /// AMM-пул с x*y=k логикой
    public struct SwapPool<phantom T, phantom U> has key {
        id: UID,
        token_a: Balance<T>,
        token_b: Balance<U>,
        lp_supply: Balance<LPToken>, // хранит общее количество LP
    }

    /// События для Swap и Liquidity действий
    public struct SwapEvent has drop, store {
        direction: vector<u8>,
        input_amount: u64,
        output_amount: u64
    }

    public struct LiquidityEvent has drop, store {
        action: vector<u8>, // "add" или "remove"
        lp_amount: u64
    }

    /// Возвращает текущую цену: сколько B за 1 A (в целых числах, без учета комиссии)
    public fun get_price<T: copy + drop + store, U: copy + drop + store>(
        pool: &SwapPool<T, U>
    ): u64 {
        let reserve_a = Balance::value(&pool.token_a);
        let reserve_b = Balance::value(&pool.token_b);
        if (reserve_a == 0) {
            0
        } else {
            reserve_b / reserve_a
        }
    }

    /// Инициализация пула
    public fun init_pool<T: copy + drop + store, U: copy + drop + store>(
        coin_a: Coin<T>,
        coin_b: Coin<U>,
        treasury_cap: &mut TreasuryCap<LPToken>,
        ctx: &mut TxContext
    ): (SwapPool<T, U>, Coin<LPToken>) {
        let (bal_a, _) = Balance::split(&coin_a, value(&coin_a));
        let (bal_b, _) = Balance::split(&coin_b, value(&coin_b));
        let init_lp = 1_000_000;

        let lp_coin = coin::mint<LPToken>(treasury_cap, init_lp, ctx);
        let (lp_bal, _) = Balance::split(&lp_coin, init_lp);

        let pool = SwapPool {
            id: UID::new(ctx),
            token_a: bal_a,
            token_b: bal_b,
            lp_supply: lp_bal,
        };

        event::emit(LiquidityEvent { action: b"init", lp_amount: init_lp });

        (pool, lp_coin)
    }

    /// Добавление ликвидности
    public fun add_liquidity<T: copy + drop + store, U: copy + drop + store>(
        pool: &mut SwapPool<T, U>,
        coin_a: Coin<T>,
        coin_b: Coin<U>,
        treasury_cap: &mut TreasuryCap<LPToken>,
        ctx: &mut TxContext
    ): Coin<LPToken> {
        let amt_a = value(&coin_a);
        let amt_b = value(&coin_b);

        let reserve_a = Balance::value(&pool.token_a);
        let reserve_b = Balance::value(&pool.token_b);
        let total_lp = Balance::value(&pool.lp_supply);

        let lp_to_mint = if (reserve_a == 0 || reserve_b == 0) {
            0
        } else {
            let lp1 = amt_a * total_lp / reserve_a;
            let lp2 = amt_b * total_lp / reserve_b;
            if (lp1 < lp2) { lp1 } else { lp2 }
        };

        coin::merge(&mut pool.token_a, coin_a);
        coin::merge(&mut pool.token_b, coin_b);

        let lp_coin = coin::mint<LPToken>(treasury_cap, init_lp, ctx);
        let (new_lp_bal, _) = Balance::split(&lp_coin, lp_to_mint);
        coin::merge(&mut pool.lp_supply, lp_coin);

        event::emit(LiquidityEvent { action: b"add", lp_amount: lp_to_mint });

        from_balance(new_lp_bal, ctx)
    }

    /// Удаление ликвидности
    public fun remove_liquidity<T: copy + drop + store, U: copy + drop + store>(
        pool: &mut SwapPool<T, U>,
        lp_token: Coin<LPToken>,
        treasury_cap: &mut TreasuryCap<LPToken>,
        ctx: &mut TxContext
    ): (Coin<T>, Coin<U>) {
        let lp_amount = value(&lp_token);
        let total = Balance::value(&pool.lp_supply);

        let reserve_a = Balance::value(&pool.token_a);
        let reserve_b = Balance::value(&pool.token_b);

        let out_a = reserve_a * lp_amount / total;
        let out_b = reserve_b * lp_amount / total;

        let lp_left = lp_token.split(lp_amount, ctx); // сжигаем LP
        coin::burn(treasury_cap, lp_left);

        let (out_bal_a, new_a) = Balance::split(&mut pool.token_a, out_a);
        let (out_bal_b, new_b) = Balance::split(&mut pool.token_b, out_b);
        pool.token_a = new_a;
        pool.token_b = new_b;

        let (_, new_lp_supply) = Balance::split(&mut pool.lp_supply, lp_amount);
        pool.lp_supply = new_lp_supply;

        event::emit(LiquidityEvent { action: b"remove", lp_amount });

        (
            from_balance(out_bal_a, ctx),
            from_balance(out_bal_b, ctx)
        )
    }

    public fun swap_a_for_b<phantom T: copy + drop + store, phantom U: copy + drop + store>(
        pool: &mut SwapPool<T, U>,
        input: Coin<T>,
        ctx: &mut TxContext
    ): Coin<U> {
        let amount_in = coin::value(&input);

        let reserve_a = Balance::value(&pool.token_a);
        let reserve_b = Balance::value(&pool.token_b);

        // комиссия 0.3% (997 / 1000)
        let amount_in_with_fee = amount_in * 997;
        let numerator = amount_in_with_fee * reserve_b;
        let denominator = reserve_a * 1000 + amount_in_with_fee;
        let amount_out = numerator / denominator;

        // Забираем A, отдаём B
        coin::merge(&mut pool.token_a, input);
        let (out_b, new_pool_b) = Balance::split(&mut pool.token_b, amount_out);
        pool.token_b = new_pool_b;
        event::emit(SwapEvent { direction: b"AtoB", input_amount: amount_in, output_amount: amount_out });

        Coin::from_balance(out_b, ctx)
    }

    public fun swap_b_for_a<phantom T: copy + drop + store, phantom U: copy + drop + store>(
        pool: &mut SwapPool<T, U>,
        input: Coin<U>,
        ctx: &mut TxContext
    ): Coin<T> {
        let amount_in = coin::value(&input);

        let reserve_a = Balance::value(&pool.token_a);
        let reserve_b = Balance::value(&pool.token_b);

        let amount_in_with_fee = amount_in * 997;
        let numerator = amount_in_with_fee * reserve_a;
        let denominator = reserve_b * 1000 + amount_in_with_fee;
        let amount_out = numerator / denominator;

        coin::merge(&mut pool.token_b, input);
        let (out_a, new_pool_a) = Balance::split(&mut pool.token_a, amount_out);
        pool.token_a = new_pool_a;
        event::emit(SwapEvent { direction: b"BtoA", input_amount: amount_in, output_amount: amount_out });

        Coin::from_balance(out_a, ctx)
    }
}