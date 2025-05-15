module riot_defi::coin {
    use sui::transfer;
    use sui::coin;

    /// LP-токен как coin
    public struct LPToken has store, drop {}

     public fun init(witness: LPToken, ctx: &mut TxContext) {
         let (treasury, metadata) = coin::create_currency(
             witness,
             6,
             b"RIOT_DEFI",
             b"RiotDefi Coin",
             b"Coin for support RiotDefi product",
             option::none(),
             ctx,
         );
         transfer::public_freeze_object(metadata);
         transfer::public_transfer(treasury, ctx.sender())
     }

}