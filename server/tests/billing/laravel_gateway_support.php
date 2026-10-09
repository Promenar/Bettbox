<?php

namespace BettboxBillingFixture;

use Illuminate\Support\Facades\DB;

// 真实目录加载验收之后才定义传输替身，避免预加载遮蔽require回退。
final class FubeiGateway extends \Plugin\Fubei\Plugin
{
    protected function client(): \Plugin\Fubei\Client
    {
        return new \Plugin\Fubei\Client($this->getConfig(), 'public-fixture-not-a-credential', static function ($url, $body): string {
            $request=json_decode($body,true,32,JSON_THROW_ON_ERROR);
            $biz=json_decode($request['biz_content'],true,32,JSON_THROW_ON_ERROR);
            DB::table('fixture_gateway')->insert(['trade_no'=>$biz['merchant_order_sn'],'amount'=>\Plugin\Fubei\Amount::fromYuan((string)$biz['total_amount'])]);
            return json_encode(['result_code'=>200,'data'=>json_encode(['merchant_order_sn'=>$biz['merchant_order_sn'],'qrcode_url'=>'https://pay.example.test/fixture'])],JSON_THROW_ON_ERROR);
        });
    }
}
