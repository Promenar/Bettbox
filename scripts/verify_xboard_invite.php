<?php
/**
 * 在 Xboard 根目录运行：php /path/to/verify_xboard_invite.php --run-in-memory
 * 只读源库的结构和公开返佣配置；业务操作仅进入独立内存库。
 * 默认只做预检。禁止输出响应体、异常消息、账号、邀请码或认证材料。
 */

use App\Models\CommissionLog;
use App\Models\InviteCode;
use App\Models\Order;
use App\Models\Plan;
use App\Models\User;
use App\Services\AuthService;
use App\Services\OrderService;
use App\Services\UserService;
use App\Utils\CacheKey;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Bus;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Mail;
use Illuminate\Support\Facades\Queue;

ini_set('display_errors', '0');
ini_set('log_errors', '0');
$stage = 'preflight';
$checks = [];
ob_start();

function check(bool $condition, string $label): void
{
    global $stage, $checks;
    $stage = $label;
    if (!$condition) {
        throw new RuntimeException('断言失败');
    }
    $checks[] = $label;
}

try {
    $root = getcwd();
    check(is_file($root . '/vendor/autoload.php') && extension_loaded('pdo_sqlite'), 'runtime_available');
    check(is_dir($root . '/plugins') && is_dir($root . '/plugins-core'), 'plugin_directories_exist');
    $running = in_array('--run-in-memory', $argv ?? [], true);
    if ($running) {
        // 执行器必须使用无网络、只读根和只读源卷的临时容器。
        check(getenv('BETTBOX_VERIFY_ISOLATED_CONTAINER') === '1', 'isolated_executor_declared');
        $temporary = sys_get_temp_dir() . '/bettbox-invite-' . bin2hex(random_bytes(8));
        mkdir($temporary, 0700, true);
        foreach (['services', 'packages', 'events', 'routes', 'config'] as $name) {
            putenv('APP_' . strtoupper($name) . '_CACHE=' . $temporary . '/' . $name . '.php');
        }
    }
    require $root . '/vendor/autoload.php';
    $app = require $root . '/bootstrap/app.php';
    // 只加载环境与配置，隔离完成前禁止启动服务提供者。
    (new Illuminate\Foundation\Bootstrap\LoadEnvironmentVariables())->bootstrap($app);
    (new Illuminate\Foundation\Bootstrap\LoadConfiguration())->bootstrap($app);
    $config = $app->make('config');
    $sourceConfig = $config->get('database.connections.' . $config->get('database.default'));
    check(($sourceConfig['driver'] ?? null) === 'sqlite', 'source_is_sqlite');
    $sourcePath = realpath($sourceConfig['database'] ?? '');
    check($sourcePath !== false && is_file($sourcePath), 'source_exists');
    if ($running) {
        $mounts = json_decode(getenv('BETTBOX_VERIFY_SOURCE_MOUNTS') ?: '[]', true);
        $covered = false;
        foreach ($mounts as $mount) {
            if ($sourcePath === $mount || str_starts_with($sourcePath, rtrim($mount, '/') . '/')) $covered = true;
        }
        check($covered && !is_writable($sourcePath), 'source_on_read_only_mount');
    }
    $source = new PDO('sqlite:' . $sourcePath, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::SQLITE_ATTR_OPEN_FLAGS => PDO::SQLITE_OPEN_READONLY]);
    $source->exec('PRAGMA query_only=ON');
    check((int) $source->query('PRAGMA query_only')->fetchColumn() === 1, 'source_read_only');
    $ddl = $source->query("SELECT sql FROM sqlite_master WHERE type IN ('table','index') AND sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY CASE type WHEN 'table' THEN 0 ELSE 1 END")->fetchAll(PDO::FETCH_COLUMN);
    $defaults = [
        'invite_commission' => 10, 'invite_never_expire' => 0, 'invite_gen_limit' => 5,
        'commission_first_time_enable' => 1, 'commission_auto_check_enable' => 1,
        'commission_distribution_enable' => 0, 'commission_distribution_l1' => 100,
        'commission_distribution_l2' => 0, 'commission_distribution_l3' => 0,
        'withdraw_close_enable' => 0,
    ];
    $publicSettings = $defaults;
    $query = $source->prepare('SELECT value FROM v2_settings WHERE name = ?');
    foreach ($defaults as $key => $default) {
        $query->execute([$key]);
        $value = $query->fetchColumn();
        if ($value !== false) {
            $decoded = json_decode($value, true);
            check(is_numeric($decoded ?? $value), 'numeric_setting_' . $key);
            $publicSettings[$key] = (float) ($decoded ?? $value);
        }
        $number = $publicSettings[$key];
        $maximum = str_contains($key, 'enable') || $key === 'invite_never_expire' ? 1 : 100;
        $minimum = $key === 'invite_gen_limit' ? 1 : 0;
        if ($key === 'invite_gen_limit') $maximum = PHP_INT_MAX;
        check($number >= $minimum && $number <= $maximum && floor($number) === (float) $number, 'setting_range_' . $key);
        $publicSettings[$key] = (int) $number;
    }
    // 不保留任何通向源库的连接，不复制用户、订单、插件或认证表数据。
    unset($query, $source, $sourceConfig, $sourcePath);
    if (!$running) {
        ob_end_clean();
        echo json_encode(['ok' => true, 'mode' => 'preflight', 'checks' => $checks]) . PHP_EOL;
        exit(0);
    }

    $stage = 'isolation';
    $app->useStoragePath($temporary . '/storage');
    $config->set('view.compiled', $temporary . '/storage/framework/views');
    foreach (['logs', 'framework/views', 'framework/cache', 'framework/sessions'] as $directory) {
        mkdir($temporary . '/storage/' . $directory, 0700, true);
    }
    $config->set('database.default', 'invite_memory');
    $config->set('database.connections', ['invite_memory' => [
        'driver' => 'sqlite', 'database' => ':memory:', 'prefix' => '',
        'foreign_key_constraints' => true,
    ]]);
    // Horizon 注册只需连接定义；无网络容器及 array cache 阻止真实 Redis 使用。
    $config->set('database.redis', ['client' => 'phpredis', 'default' => ['host' => '127.0.0.1', 'port' => 1, 'database' => 0]]);
    $config->set('horizon.use', 'default');
    $config->set('cache.default', 'array');
    $config->set('cache.stores', ['array' => ['driver' => 'array'], 'redis' => ['driver' => 'array']]);
    $config->set('queue.default', 'sync');
    $config->set('queue.connections', ['sync' => ['driver' => 'sync']]);
    $config->set('mail.default', 'array');
    $config->set('mail.mailers', ['array' => ['transport' => 'array']]);
    $config->set('session.driver', 'array');
    $config->set('logging.default', 'null');
    $config->set('logging.channels', ['null' => ['driver' => 'monolog', 'handler' => Monolog\Handler\NullHandler::class]]);
    $config->set('v2board', []);
    $config->set('app.debug', false);
    $config->set('app.env', 'testing');
    $app->detectEnvironment(fn () => 'testing');
    foreach (['RegisterFacades', 'SetRequestForConsole', 'RegisterProviders', 'BootProviders'] as $bootstrap) {
        $app->beforeBootstrapping('Illuminate\\Foundation\\Bootstrap\\' . $bootstrap, function () use ($bootstrap) {
            global $stage;
            $stage = 'bootstrap_' . $bootstrap;
        });
    }
    // 后续 Kernel 的 bootstrap 不得再次加载源站环境与连接配置。
    $app->bootstrapWith([
        Illuminate\Foundation\Bootstrap\RegisterFacades::class,
        Illuminate\Foundation\Bootstrap\SetRequestForConsole::class,
        Illuminate\Foundation\Bootstrap\RegisterProviders::class,
        Illuminate\Foundation\Bootstrap\BootProviders::class,
    ]);
    Queue::fake();
    Bus::fake();
    Mail::fake();
    Http::preventStrayRequests();
    $pdo = DB::connection()->getPdo();
    check(DB::connection()->getDatabaseName() === ':memory:', 'memory_database');
    foreach ($ddl as $sql) {
        $pdo->exec($sql);
    }
    $fixtureSettings = [
        'email_verify' => 1, 'invite_force' => 1, 'stop_register' => 0,
        'register_limit_by_ip_enable' => 0, 'email_whitelist_enable' => 0,
        'email_gmail_limit_enable' => 0, 'captcha_enable' => 0,
        'app_url' => 'https://invite.example.test', 'try_out_plan_id' => 0,
    ];
    foreach (array_merge($publicSettings, $fixtureSettings) as $key => $value) {
        App\Models\Setting::createOrUpdate($key, $value);
    }
    Cache::store('redis')->forget(App\Support\Setting::CACHE_KEY);
    $app->forgetInstance(App\Support\Setting::class);
    check(User::count() === 0 && Order::count() === 0, 'empty_business_tables');

    $kernel = $app->make(Illuminate\Contracts\Http\Kernel::class);
    $request = function (string $method, string $path, array $data = [], ?string $authorization = null) use ($app, $kernel): array {
        Auth::forgetGuards();
        $headers = ['HTTP_ACCEPT' => 'application/json', 'REMOTE_ADDR' => '127.0.0.1'];
        if ($authorization !== null) $headers['HTTP_AUTHORIZATION'] = $authorization;
        $req = Illuminate\Http\Request::create('https://invite.example.test' . $path, $method, $data, [], [], $headers);
        $app->instance('request', $req);
        $response = $kernel->handle($req);
        return [$response->getStatusCode(), json_decode($response->getContent(), true)];
    };

    $stage = 'create_inviter';
    $inviter = app(UserService::class)->createUser(['email' => 'inviter@example.test', 'password' => bin2hex(random_bytes(16))]);
    $inviter->commission_type = User::COMMISSION_TYPE_SYSTEM;
    $inviter->commission_rate = null;
    $inviter->balance = 0;
    $inviter->commission_balance = 0;
    $inviter->save();
    $authorization = (new AuthService($inviter))->generateAuthData()['auth_data'];
    [$status, $body] = $request('GET', '/api/v1/user/invite/save', [], $authorization);
    check($status === 200 && ($body['data'] ?? null) === true, 'invite_created_through_kernel');
    $code = InviteCode::where('user_id', $inviter->id)->firstOrFail()->code;
    $registerData = ['email' => 'invitee@example.test', 'password' => bin2hex(random_bytes(16)), 'invite_code' => $code, 'email_code' => '123456'];
    [$status] = $request('POST', '/api/v1/passport/auth/register', array_replace($registerData, ['email' => 'invalid']));
    check($status === 422 && User::count() === 1, 'invalid_email_rejected');
    [$status] = $request('POST', '/api/v1/passport/auth/register', $registerData);
    check($status >= 400 && $status < 500 && User::count() === 1, 'missing_cached_email_code_rejected');
    Cache::put(CacheKey::get('EMAIL_VERIFY_CODE', $registerData['email']), '123456', 300);
    [$status] = $request('POST', '/api/v1/passport/auth/register', $registerData);
    check($status === 200 && User::count() === 2, 'registration_succeeded');
    $invitee = User::byEmail($registerData['email'])->firstOrFail();
    check((int) $invitee->invite_user_id === (int) $inviter->id, 'inviter_bound');
    check(Cache::get(CacheKey::get('EMAIL_VERIFY_CODE', $registerData['email'])) === null, 'email_code_consumed');

    $stage = 'create_order';
    $plan = Plan::create(['name' => '内存验证套餐', 'transfer_enable' => 10, 'show' => true, 'sell' => true, 'renew' => true,
        'prices' => ['monthly' => 100], 'capacity_limit' => null, 'reset_traffic_method' => Plan::RESET_TRAFFIC_NEVER, 'sort' => 0]);
    $order = OrderService::createFromRequest($invitee, $plan, Plan::PERIOD_MONTHLY, null);
    $expected = (float) (10000 * $publicSettings['invite_commission'] / 100);
    check((int) $order->total_amount === 10000 && (float) $order->commission_balance === $expected, 'commission_calculated');
    // 只模拟付款完成事实；不调用支付网关、付款回调或套餐开通。
    DB::table($order->getTable())->where('id', $order->id)->update(['status' => Order::STATUS_COMPLETED, 'commission_status' => 0, 'updated_at' => time() - 259201]);
    if ($publicSettings['commission_distribution_enable']) $expected *= $publicSettings['commission_distribution_l1'] / 100;
    [$status, $body] = $request('GET', '/api/v1/user/invite/fetch', [], $authorization);
    $before = $body['data']['stat'] ?? [];
    check($status === 200 && count($before) === 5 && $before[0] === 1 && (float) $before[2] === $expected, 'pending_commission_visible');
    if (!$publicSettings['commission_auto_check_enable']) {
        DB::table($order->getTable())->where('id', $order->id)->update(['commission_status' => 1]);
    }
    $stage = 'settle';
    Artisan::call('check:commission');
    $order->refresh();
    $inviter->refresh();
    $balanceField = $publicSettings['withdraw_close_enable'] ? 'balance' : 'commission_balance';
    check((int) $order->commission_status === 2 && (float) $order->actual_commission_balance === $expected, 'order_settled');
    check((float) $inviter->{$balanceField} === $expected && CommissionLog::where('trade_no', $order->trade_no)->count() === ($expected > 0 ? 1 : 0), 'commission_credited_once');
    $snapshot = [$inviter->balance, $inviter->commission_balance, $order->actual_commission_balance, CommissionLog::count()];
    Artisan::call('check:commission');
    $order->refresh();
    $inviter->refresh();
    check($snapshot === [$inviter->balance, $inviter->commission_balance, $order->actual_commission_balance, CommissionLog::count()], 'sequential_repeat_unchanged');
    [$status, $body] = $request('GET', '/api/v1/user/invite/fetch', [], $authorization);
    $after = $body['data']['stat'] ?? [];
    check($status === 200 && $after[0] === 1 && (float) $after[1] === $expected && (float) $after[2] === 0.0 && (float) $after[4] === (float) $inviter->commission_balance, 'settled_commission_visible');
    check($pdo === DB::connection()->getPdo() && DB::connection()->getDatabaseName() === ':memory:', 'same_memory_connection');
    ob_end_clean();
    echo json_encode(['ok' => true, 'mode' => 'memory_kernel_services_command', 'checks' => $checks,
        'public_commission_settings' => $publicSettings, 'stat_before' => $before, 'stat_after' => $after,
        'payment' => 'simulated_completed_order', 'mail_queue' => 'fake', 'source_database' => 'read_only_schema_and_allowlisted_settings',
        'concurrent_settlement' => 'not_verified', 'captcha' => 'not_verified'], JSON_UNESCAPED_UNICODE) . PHP_EOL;
} catch (Throwable $error) {
    while (ob_get_level() > 0) ob_end_clean();
    echo json_encode(['ok' => false, 'stage' => $stage, 'exception_class' => get_class($error),
        'exception_file' => basename($error->getFile()), 'exception_line' => $error->getLine(), 'checks' => $checks]) . PHP_EOL;
    exit(1);
}
