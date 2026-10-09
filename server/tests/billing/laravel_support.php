<?php

namespace BettboxBillingFixture;

use App\Contracts\PaymentInterface;
use App\Services\Plugin\AbstractPlugin;
use App\Services\Plugin\PluginManager;
use Illuminate\Support\Facades\DB;

// 保留应用真实异常处理，仅记录不含 message、请求、响应或堆栈参数的定位证据。
final class WitnessHandler extends \App\Exceptions\Handler
{
    private function witness(\Throwable $exception): void
    {
        // 容器包装异常时定位最内层异常，避免只得到外层包装器的位置。
        for ($depth=0; $depth<4 && $exception->getPrevious()!==null; $depth++) $exception=$exception->getPrevious();
        $GLOBALS['fixture_http_witness']=[
            'exception_class'=>get_class($exception),
            'exception_file'=>basename($exception->getFile()),
            'exception_line'=>$exception->getLine(),
        ];
        // 只从两种完整固定句式提取公开标识；原始异常文本绝不进入输出。
        if (preg_match('/\AClass "([A-Za-z_][A-Za-z0-9_.\\\\]{0,159})" does not exist\z/D',$exception->getMessage(),$match)
            || preg_match('/\ATarget class \[([A-Za-z_][A-Za-z0-9_.\\\\]{0,159})\] does not exist\.\z/D',$exception->getMessage(),$match)) {
            $GLOBALS['fixture_http_witness']['missing_identifier']=$match[1];
        }
    }

    public function report(\Throwable $exception)
    {
        $this->witness($exception);
        parent::report($exception);
    }

    public function render($request, \Throwable $exception)
    {
        $this->witness($exception);
        return parent::render($request,$exception);
    }
}

// 仅替换插件目录发现；付款服务、配置注入和 HookManager 使用真实应用代码。
final class PluginDiscovery extends PluginManager
{
    public array $fixtures = [];
    public function initializeEnabledPlugins(): void {}
    public function getEnabledPaymentPlugins(): array { return $this->fixtures; }
}

final class LegacyGateway extends AbstractPlugin implements PaymentInterface
{
    public function form(): array { return []; }
    public function pay($order): array
    {
        DB::table('fixture_gateway')->insert(['trade_no'=>$order['trade_no'], 'amount'=>$order['total_amount']]);
        return ['type'=>0,'data'=>'PUBLIC_FIXTURE_QR'];
    }
    public function notify($params)
    {
        // 旧网关验签不在此验收范围；只返回公开 fixture 的已付款事实。
        return ['trade_no'=>$params['trade_no'],'callback_no'=>$params['callback_no'],'custom_result'=>'success'];
    }
}
