<?php
/**
 * Laravel 隔离验收；默认不启动框架。仅由主控的禁网临时容器执行。
 * --execute --vendor-root=/runtime/vendor --public-root=/source/xboard-public
 * --candidate-root=/source/bettbox --work-root=/work
 * 不使用源站 bootstrap、环境、配置、数据库或插件目录；不安装依赖。
 */

ini_set('display_errors','0');
ini_set('log_errors','0');
$stage='preflight'; $checks=[]; $hashes=[]; $temporary=null;
ob_start();

function fixtureCheck(bool $value,string $label): void
{
    global $stage,$checks;
    $stage=$label;
    if (!$value) throw new RuntimeException('隔离验收断言失败');
    $checks[]=$label;
}

function fixtureFile(string $root,string $relative): string
{
    global $hashes;
    if ($relative==='' || str_starts_with($relative,'/') || in_array('..',explode('/',$relative),true)) throw new RuntimeException('输入路径拒绝');
    $path=$root.'/'.$relative;
    $cursor=$root;
    foreach (explode('/',$relative) as $part) {
        $cursor.='/'.$part;
        if (is_link($cursor)) throw new RuntimeException('输入链接拒绝');
    }
    if (!is_file($path) || realpath($path)!==$path) throw new RuntimeException('公开输入缺失或身份不明');
    $hashes[$path]=hash_file('sha256',$path);
    return $path;
}

function fixtureRemove(string $directory): void
{
    if (!is_dir($directory) || is_link($directory)) return;
    foreach (new FilesystemIterator($directory,FilesystemIterator::SKIP_DOTS) as $entry) {
        if ($entry->isDir() && !$entry->isLink()) fixtureRemove($entry->getPathname());
        else if (!unlink($entry->getPathname())) throw new RuntimeException('临时文件清理失败');
    }
    if (!rmdir($directory)) throw new RuntimeException('临时目录清理失败');
}

try {
    $options=getopt('', ['execute','vendor-root:','public-root:','candidate-root:','work-root:']);
    if (!isset($options['execute'])) {
        ob_end_clean();
        echo json_encode(['mode'=>'plan','execution'=>'主控禁网一次性容器','database'=>'独立空 SQLite 文件','source_environment_loaded'=>false],JSON_UNESCAPED_UNICODE).PHP_EOL;
        exit(0);
    }
    fixtureCheck(getenv('BETTBOX_VERIFY_ISOLATED_CONTAINER')==='1','isolated_executor_declared');
    fixtureCheck(extension_loaded('pdo_sqlite'),'pdo_sqlite_available');
    $roots=[];
    foreach (['vendor-root','public-root','candidate-root','work-root'] as $name) {
        $value=$options[$name]??'';
        fixtureCheck(is_string($value) && $value!=='' && !is_link($value) && is_dir($value),'root_'.$name);
        $roots[$name]=realpath($value);
    }
    [$vendor,$public,$candidate,$work]=array_values($roots);
    fixtureCheck(!is_writable($public) && !is_writable($candidate),'source_mounts_read_only');
    $temporary=$work.'/laravel-billing-'.bin2hex(random_bytes(12));
    fixtureCheck(mkdir($temporary,0700),'unique_work_created');
    foreach (['empty-environment','bootstrap/cache','storage/logs','storage/framework/views','storage/framework/cache','storage/framework/sessions','resources/views','lang','routes','app/Console/Commands','plugins','plugins-core'] as $directory) mkdir($temporary.'/'.$directory,0700,true);
    foreach (['CONFIG','SERVICES','PACKAGES','EVENTS','ROUTES'] as $key) putenv('APP_'.$key.'_CACHE='.$temporary.'/bootstrap/cache/'.strtolower($key).'.php');
    putenv('APP_ENV=testing'); putenv('APP_BASE_PATH='.$temporary); putenv('DB_CONNECTION=fixture'); putenv('DB_DATABASE='.$temporary.'/fixture.sqlite');
    $_ENV['APP_BASE_PATH']=$temporary;

    // 只加载 vendor 的 Composer 映射和 helper；排除其源站 App/Plugin 路径与 helper。
    // 不 require 源站 vendor/autoload.php，以免执行其中的应用 autoload.files。
    require fixtureFile($vendor,'composer/ClassLoader.php');
    $loader=new Composer\Autoload\ClassLoader($vendor);
    foreach (require fixtureFile($vendor,'composer/autoload_psr4.php') as $prefix=>$paths) {
        $safe=array_values(array_filter($paths,fn($path)=>str_starts_with(realpath($path)?:'',$vendor.'/')));
        if ($safe) $loader->addPsr4($prefix,$safe);
    }
    $vendorMap=[];
    foreach (require fixtureFile($vendor,'composer/autoload_classmap.php') as $class=>$path) {
        if (str_starts_with(realpath($path)?:'',$vendor.'/')) $vendorMap[$class]=$path;
    }
    $loader->addClassMap($vendorMap); $loader->register();
    foreach (require fixtureFile($vendor,'composer/autoload_files.php') as $id=>$path) {
        if (str_starts_with(realpath($path)?:'',$vendor.'/') && empty($GLOBALS['__composer_autoload_files'][$id])) {
            $GLOBALS['__composer_autoload_files'][$id]=true;
            require $path;
        }
    }

    $applicationClasses=[
        'App\\Http\\Kernel','App\\Http\\Controllers\\Controller','App\\Helpers\\ApiResponse','App\\Helpers\\ResponseEnum',
        'App\\Exceptions\\ApiException','App\\Exceptions\\BusinessException','App\\Exceptions\\Handler','App\\Contracts\\PaymentInterface',
        'App\\Http\\Middleware\\TrustProxies','App\\Http\\Middleware\\CheckForMaintenanceMode','App\\Http\\Middleware\\TrimStrings',
        'App\\Http\\Middleware\\InitializePlugins','App\\Http\\Middleware\\ApplyRuntimeSettings','App\\Http\\Middleware\\ForceJson','App\\Http\\Middleware\\Language',
        'App\\Models\\User','App\\Models\\Plan','App\\Models\\Order','App\\Models\\Payment','App\\Models\\Setting','App\\Models\\CommissionLog','App\\Models\\TrafficResetLog',
        'App\\Services\\UserService','App\\Services\\PlanService','App\\Services\\TrafficResetService','App\\Services\\PaymentService',
        'App\\Services\\Plugin\\PluginManager','App\\Services\\Plugin\\AbstractPlugin','App\\Services\\Plugin\\HookManager','App\\Services\\Plugin\\InterceptResponseException',
        'App\\Support\\Setting','App\\Utils\\Helper',
    ];
    $appMap=[];
    foreach ($applicationClasses as $class) $appMap[$class]=fixtureFile($public,'app/'.str_replace('\\','/',substr($class,4)).'.php');
    foreach (['Services/Billing/Atomic','Services/Billing/Outbox','Services/Billing/AtomicMigration','Services/OrderService','Jobs/OrderHandleJob','Console/Commands/CheckCommission','Console/Commands/CheckOrder','Console/Commands/BillingMigrate','Http/Controllers/V1/User/OrderController','Http/Controllers/V1/Guest/PaymentController'] as $class) {
        $appMap['App\\'.str_replace('/','\\',$class)]=fixtureFile($candidate,'server/patches/billing/overlay/app/'.$class.'.php');
    }
    $appMap['Plugin\\Fubei\\Plugin']=fixtureFile($candidate,'server/plugins/Fubei/Plugin.php');
    foreach (['Amount','Client','JsonAmount','Notification','RawNotification','Signature'] as $name) fixtureFile($candidate,'server/plugins/Fubei/'.$name.'.php');
    $loader->addClassMap($appMap);
    spl_autoload_register(static function ($class) use ($appMap) {
        if ((str_starts_with($class,'App\\') || str_starts_with($class,'Plugin\\')) && !isset($appMap[$class])) throw new RuntimeException('应用类不在公开白名单');
    },true,true);
    require fixtureFile($public,'app/Helpers/Functions.php');
    require fixtureFile($candidate,'server/tests/billing/laravel_support.php');
    fixtureCheck(class_exists(Illuminate\Foundation\Application::class),'laravel_vendor_available');
    $app=new Illuminate\Foundation\Application($temporary);
    $app->useEnvironmentPath($temporary.'/empty-environment')->loadEnvironmentFrom('absent.env');
    $app->useStoragePath($temporary.'/storage');
    $app->detectEnvironment(fn()=>'testing');
    $app->instance('config',new Illuminate\Config\Repository([
        'app'=>['name'=>'公开账务隔离验收','env'=>'testing','debug'=>false,'url'=>'https://fixture.example.test','key'=>'base64:'.base64_encode(str_repeat('F',32)),'cipher'=>'AES-256-CBC','timezone'=>'UTC','locale'=>'en','fallback_locale'=>'en','providers'=>[]],
        'database'=>['default'=>'fixture','connections'=>['fixture'=>['driver'=>'sqlite','database'=>$temporary.'/fixture.sqlite','prefix'=>'','foreign_key_constraints'=>true,'busy_timeout'=>5000]],'redis'=>['client'=>'phpredis','default'=>['host'=>'127.0.0.1','port'=>1,'database'=>0]]],
        'cache'=>['default'=>'array','stores'=>['array'=>['driver'=>'array'],'redis'=>['driver'=>'array']]],
        'queue'=>['default'=>'sync','connections'=>['sync'=>['driver'=>'sync']]],
        'mail'=>['default'=>'array','mailers'=>['array'=>['transport'=>'array']]],
        'session'=>['driver'=>'array','cookie'=>'fixture_session','lifetime'=>120,'files'=>$temporary.'/storage/framework/sessions'],
        'logging'=>['default'=>'null','channels'=>['null'=>['driver'=>'monolog','handler'=>Monolog\Handler\NullHandler::class]]],
        'filesystems'=>['default'=>'local','disks'=>['local'=>['driver'=>'local','root'=>$temporary.'/storage']]],
        'view'=>['paths'=>[$temporary.'/resources/views'],'compiled'=>$temporary.'/storage/framework/views'],
        'auth'=>['defaults'=>['guard'=>'web','passwords'=>'users'],'guards'=>['web'=>['driver'=>'session','provider'=>'users']],'providers'=>['users'=>['driver'=>'eloquent','model'=>App\Models\User::class]]],
        'hashing'=>['driver'=>'bcrypt','bcrypt'=>['rounds'=>4]],
        'payments'=>['fubei'=>['secrets'=>['public_fixture'=>'public-fixture-not-a-credential']]],
        'v2board'=>['app_url'=>'https://fixture.example.test','invite_commission'=>10,'commission_first_time_enable'=>0,'commission_auto_check_enable'=>0,'commission_distribution_enable'=>0,'withdraw_close_enable'=>0,'reset_traffic_method'=>2],
    ]));
    $app->singleton(Illuminate\Contracts\Http\Kernel::class,App\Http\Kernel::class);
    $app->singleton(Illuminate\Contracts\Console\Kernel::class,Illuminate\Foundation\Console\Kernel::class);
    $app->singleton(Illuminate\Contracts\Debug\ExceptionHandler::class,BettboxBillingFixture\WitnessHandler::class);
    // Auth SessionGuard 的 CookieJar 依赖必须由真实框架服务提供，API 中间件也会触发该解析。
    $app->register(Illuminate\Cookie\CookieServiceProvider::class);
    foreach ([Illuminate\Auth\AuthServiceProvider::class,Illuminate\Bus\BusServiceProvider::class,Illuminate\Cache\CacheServiceProvider::class,Illuminate\Database\DatabaseServiceProvider::class,Illuminate\Encryption\EncryptionServiceProvider::class,Illuminate\Filesystem\FilesystemServiceProvider::class,Illuminate\Hashing\HashServiceProvider::class,Illuminate\Mail\MailServiceProvider::class,Illuminate\Queue\QueueServiceProvider::class,Illuminate\Session\SessionServiceProvider::class,Illuminate\Translation\TranslationServiceProvider::class,Illuminate\Validation\ValidationServiceProvider::class,Illuminate\View\ViewServiceProvider::class,Illuminate\Foundation\Providers\FoundationServiceProvider::class] as $provider) $app->register($provider);
    // 标记框架已安全 bootstrap，HTTP/Console Kernel 不再运行环境、配置或 provider 自动发现。
    $app->bootstrapWith([Illuminate\Foundation\Bootstrap\RegisterFacades::class,Illuminate\Foundation\Bootstrap\SetRequestForConsole::class]);
    $app->boot();
    Illuminate\Support\Facades\Http::preventStrayRequests();
    touch($temporary.'/fixture.sqlite');
    $db=Illuminate\Support\Facades\DB::connection(); $pdo=$db->getPdo();
    fixtureCheck($db->getDatabaseName()===$temporary.'/fixture.sqlite','dedicated_file_database');
    require fixtureFile($candidate,'server/tests/billing/laravel_migration_check.php');
    fixtureMigrationLifecycle($db,$candidate);
    // 公开迁移字段的空 DDL；不复制源表或运行含外部 Artisan 副作用的应用迁移。
    $pdo->exec(<<<'SQL'
CREATE TABLE v2_user(id INTEGER PRIMARY KEY AUTOINCREMENT,invite_user_id INTEGER NULL,plan_id INTEGER NULL,group_id INTEGER NULL,email TEXT UNIQUE,password TEXT,token TEXT,uuid TEXT,transfer_enable INTEGER DEFAULT 0,u INTEGER DEFAULT 0,d INTEGER DEFAULT 0,expired_at INTEGER NULL,balance INTEGER DEFAULT 0,commission_balance INTEGER DEFAULT 0,commission_type INTEGER DEFAULT 1,commission_rate INTEGER NULL,discount INTEGER NULL,speed_limit INTEGER NULL,device_limit INTEGER NULL,next_reset_at INTEGER NULL,last_reset_at INTEGER NULL,reset_count INTEGER DEFAULT 0,banned INTEGER DEFAULT 0,is_admin INTEGER DEFAULT 0,created_at INTEGER,updated_at INTEGER);
CREATE TABLE v2_plan(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT,prices TEXT,transfer_enable INTEGER,group_id INTEGER NULL,speed_limit INTEGER NULL,device_limit INTEGER NULL,show INTEGER,sell INTEGER,renew INTEGER,sort INTEGER DEFAULT 0,capacity_limit INTEGER NULL,reset_traffic_method INTEGER NULL,created_at INTEGER,updated_at INTEGER);
CREATE TABLE v2_order(id INTEGER PRIMARY KEY AUTOINCREMENT,user_id INTEGER NOT NULL,plan_id INTEGER NOT NULL,invite_user_id INTEGER NULL,coupon_id INTEGER NULL,payment_id INTEGER NULL,type INTEGER,period TEXT,trade_no TEXT UNIQUE,callback_no TEXT NULL,total_amount INTEGER,handling_amount INTEGER NULL,discount_amount INTEGER NULL,surplus_amount INTEGER NULL,surplus_credit INTEGER NULL,refund_amount INTEGER NULL,balance_amount INTEGER NULL,surplus_order_ids TEXT NULL,status INTEGER DEFAULT 0,commission_status INTEGER DEFAULT 0,commission_balance INTEGER DEFAULT 0,actual_commission_balance INTEGER NULL,paid_at INTEGER NULL,created_at INTEGER,updated_at INTEGER);
CREATE TABLE v2_payment(id INTEGER PRIMARY KEY AUTOINCREMENT,uuid TEXT,payment TEXT,name TEXT,config TEXT,notify_domain TEXT NULL,enable INTEGER DEFAULT 0,handling_fee_fixed INTEGER NULL,handling_fee_percent INTEGER NULL,created_at INTEGER,updated_at INTEGER);
CREATE TABLE v2_commission_log(id INTEGER PRIMARY KEY AUTOINCREMENT,invite_user_id INTEGER,user_id INTEGER,trade_no TEXT,order_amount INTEGER,get_amount INTEGER,created_at INTEGER,updated_at INTEGER);
CREATE TABLE v2_settings(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT UNIQUE,value TEXT,created_at TEXT,updated_at TEXT);
CREATE TABLE v2_traffic_reset_logs(id INTEGER PRIMARY KEY AUTOINCREMENT,user_id INTEGER,reset_type TEXT,reset_time TEXT,old_upload INTEGER,old_download INTEGER,old_total INTEGER,new_upload INTEGER,new_download INTEGER,new_total INTEGER,trigger_source TEXT,metadata TEXT NULL,created_at TEXT,updated_at TEXT);
CREATE TABLE fixture_gateway(id INTEGER PRIMARY KEY AUTOINCREMENT,trade_no TEXT,amount INTEGER);
CREATE TABLE fixture_consumer(event_id TEXT PRIMARY KEY,order_id INTEGER);
CREATE TABLE fixture_hook_calls(id INTEGER PRIMARY KEY AUTOINCREMENT,event_id TEXT,order_id INTEGER);
SQL);
    $pdo->exec(file_get_contents(fixtureFile($candidate,'server/patches/billing/overlay/database/migrations/billing_atomic_schema.sql')));
    fixtureCheck(App\Models\User::count()===0 && App\Models\Order::count()===0,'empty_business_tables');
    Illuminate\Database\Eloquent\Model::unguard();
    $manager=new BettboxBillingFixture\PluginDiscovery();
    $legacy=new BettboxBillingFixture\LegacyGateway('FixtureLegacy');
    $fubei=new BettboxBillingFixture\FubeiGateway('Fubei');
    $manager->fixtures=[$legacy,$fubei]; $app->instance(App\Services\Plugin\PluginManager::class,$manager);
    App\Services\Plugin\HookManager::registerFilter('available_payment_methods',fn($methods)=>$methods+['FixtureLegacy'=>['plugin_code'=>'FixtureLegacy'],'Fubei'=>['plugin_code'=>'Fubei']]);
    $failOpen=null; $failConsumer=null;
    App\Services\Plugin\HookManager::register('order.open.before',function($order) use (&$failOpen) { if ($order->id===$failOpen) throw new RuntimeException('公开开通故障'); });
    App\Services\Plugin\HookManager::register('payment.notify.success',function($order) use ($db,&$failConsumer) {
        $event=$order->billing_event->id;
        $db->table('fixture_hook_calls')->insert(['event_id'=>$event,'order_id'=>$order->id]);
        $db->table('fixture_consumer')->insertOrIgnore(['event_id'=>$event,'order_id'=>$order->id]);
        if ($order->id===$failConsumer) { $failConsumer=null; throw new RuntimeException('公开消费后故障'); }
    });
    $makeUser=function($name,$invite=null,$balance=0) { return App\Models\User::create(['email'=>$name.'@example.test','password'=>'PUBLIC_FIXTURE_UNUSED','token'=>'PUBLIC_'.$name,'uuid'=>'PUBLIC_'.$name,'invite_user_id'=>$invite,'balance'=>$balance,'commission_type'=>1,'commission_rate'=>10]); };
    $inviter=$makeUser('inviter'); $buyer=$makeUser('buyer',$inviter->id,1000);
    $plan=App\Models\Plan::create(['name'=>'公开验收套餐','prices'=>['monthly'=>100],'transfer_enable'=>10,'show'=>true,'sell'=>true,'renew'=>true,'reset_traffic_method'=>2]);
    $negative=App\Models\Payment::create(['uuid'=>'PUBLIC_NEGATIVE','payment'=>'FixtureLegacy','name'=>'公开负手续费','enable'=>true,'config'=>[],'handling_fee_fixed'=>-100]);
    $positive=App\Models\Payment::create(['uuid'=>'PUBLIC_POSITIVE','payment'=>'FixtureLegacy','name'=>'公开网关','enable'=>true,'config'=>[],'handling_fee_fixed'=>100]);
    $fubeiPayment=App\Models\Payment::create(['uuid'=>'PUBLIC_FUBEI','payment'=>'Fubei','name'=>'公开付呗','enable'=>true,'config'=>['enabled'=>true,'identity_mode'=>'merchant','app_id'=>'PUBLIC_APP','merchant_id'=>123,'store_id'=>456,'secret_ref'=>'public_fixture','gateway'=>'https://gateway.example.test','gateway_hosts'=>'gateway.example.test','notify_hosts'=>'fixture.example.test','payment_hosts'=>'pay.example.test']]);
    $kernel=$app->make(Illuminate\Contracts\Http\Kernel::class);
    $app['router']->middleware('api')->post('/fixture/checkout',fn(Illuminate\Http\Request $req)=>$app->make(App\Http\Controllers\V1\User\OrderController::class)->checkout($req));
    $app['router']->middleware('api')->post('/api/v1/guest/payment/notify/{method}/{uuid}',[App\Http\Controllers\V1\Guest\PaymentController::class,'notify']);
    $request=function($path,array $data,$user=null,?string $raw=null) use ($app,$kernel) {
        $GLOBALS['fixture_http_witness']=[];
        $headers=['HTTP_ACCEPT'=>'application/json','REMOTE_ADDR'=>'127.0.0.1','CONTENT_TYPE'=>'application/x-www-form-urlencoded'];
        $req=Illuminate\Http\Request::create('https://fixture.example.test'.$path,'POST',$data,[],[],$headers,$raw);
        // Kernel 回绑 request 会重新安装 AuthManager resolver；在真实管理器中明确注入本请求的公开测试用户。
        $app['auth']->resolveUsersUsing(fn($guard=null)=>$user);
        $req->setUserResolver(fn()=>$user); $app->instance('request',$req);
        $response=$kernel->handle($req); $kernel->terminate($req,$response);
        $GLOBALS['fixture_http_witness']['http_status']=$response->getStatusCode();
        return $response;
    };
    $order=App\Services\OrderService::createFromRequest($buyer,$plan,'monthly'); $buyer->refresh();
    fixtureCheck((int)$order->total_amount===9000 && (int)$order->balance_amount===1000 && (int)$order->commission_balance===900 && (int)$buyer->balance===0,'create_balance_then_commission');
    try { App\Services\OrderService::createFromRequest($buyer,$plan,'monthly'); fixtureCheck(false,'unfinished_create_rejected'); }
    catch (App\Exceptions\ApiException $e) { fixtureCheck(App\Models\Order::count()===1,'unfinished_create_rechecked'); }
    fixtureCheck($request('/fixture/checkout',['trade_no'=>$order->trade_no,'method'=>$negative->id],$buyer)->getStatusCode()===400,'negative_checkout_kernel_rejected');
    $GLOBALS['fixture_http_witness']['gateway_count']=(int)$db->table('fixture_gateway')->count();
    $GLOBALS['fixture_http_witness']['review_count']=(int)$db->table('v2_billing_review')->where('order_id',$order->id)->count();
    fixtureCheck($GLOBALS['fixture_http_witness']['gateway_count']===0 && $GLOBALS['fixture_http_witness']['review_count']===1,'negative_checkout_no_gateway_and_review_committed');
    fixtureCheck($request('/fixture/checkout',['trade_no'=>$order->trade_no,'method'=>$positive->id],$buyer)->getStatusCode()===200,'legacy_checkout_kernel');
    fixtureCheck((int)$db->table('fixture_gateway')->value('amount')===9100,'legacy_gateway_exact_amount');
    $notify=fn($order)=>$request('/api/v1/guest/payment/notify/FixtureLegacy/PUBLIC_POSITIVE',['trade_no'=>$order->trade_no,'callback_no'=>'PUBLIC_CB_'.$order->id]);
    fixtureCheck($notify($order)->getStatusCode()===200,'legacy_callback_kernel_and_sync_job');
    $order->refresh(); $buyer->refresh();
    fixtureCheck((int)$order->status===3 && (int)$buyer->plan_id===(int)$plan->id && (int)$buyer->reset_count===1 && App\Models\TrafficResetLog::count()===1,'real_open_and_traffic_reset');
    $expiry=$buyer->expired_at;
    fixtureCheck($notify($order)->getStatusCode()===200,'repeat_callback_kernel'); $buyer->refresh();
    fixtureCheck($buyer->expired_at===$expiry && (int)$buyer->reset_count===1 && $db->table('fixture_consumer')->count()===1,'repeat_open_and_consumer_unchanged');
    $console=$app->make(Illuminate\Contracts\Console\Kernel::class); $console->registerCommand(new App\Console\Commands\CheckCommission());
    $console->registerCommand(new App\Console\Commands\CheckOrder());
    $order->commission_status=1; $order->save();
    fixtureCheck(Illuminate\Support\Facades\Artisan::call('check:commission')===0,'real_commission_command');
    Illuminate\Support\Facades\Artisan::call('check:commission'); $order->refresh(); $inviter->refresh();
    fixtureCheck((int)$inviter->commission_balance===900 && (int)$order->actual_commission_balance===900 && App\Models\CommissionLog::count()===1,'repeat_commission_once');
    $cancelUser=$makeUser('cancel',null,1000); $cancelOrder=App\Services\OrderService::createFromRequest($cancelUser,$plan,'monthly');
    fixtureCheck((new App\Services\OrderService($cancelOrder))->cancel(),'cancel_first');
    fixtureCheck((new App\Services\OrderService($cancelOrder))->cancel(),'cancel_repeat'); $cancelUser->refresh();
    fixtureCheck((int)$cancelUser->balance===1000,'cancel_refund_once');
    $recoveryUser=$makeUser('recovery'); $recovery=App\Services\OrderService::createFromRequest($recoveryUser,$plan,'monthly');
    $recovery->payment_id=$positive->id; $recovery->save(); $failOpen=$recovery->id;
    fixtureCheck($notify($recovery)->getStatusCode()===400,'opening_failure_kernel'); $recovery->refresh();
    fixtureCheck((int)$recovery->status===1 && $db->table('v2_billing_outbox')->where('order_id',$recovery->id)->whereNull('delivered_at')->count()===1,'opening_failure_outbox_persisted');
    $failOpen=null; $failConsumer=$recovery->id;
    fixtureCheck(Illuminate\Support\Facades\Artisan::call('check:order')===0,'real_order_compensation_command_and_sync_queue');
    fixtureCheck($db->table('v2_billing_outbox')->where('order_id',$recovery->id)->whereNull('delivered_at')->count()===1,'consumer_failure_outbox_retained');
    $db->table('v2_billing_outbox')->where('order_id',$recovery->id)->update(['lease_until'=>0]); App\Services\Billing\Outbox::drain();
    fixtureCheck($db->table('fixture_consumer')->where('order_id',$recovery->id)->count()===1 && $db->table('fixture_hook_calls')->where('order_id',$recovery->id)->count()===2 && $db->table('v2_billing_outbox')->where('order_id',$recovery->id)->whereNotNull('delivered_at')->count()===1,'outbox_at_least_once_consumer_idempotent');
    $badUser=$makeUser('negative'); $bad=App\Models\Order::create(['user_id'=>$badUser->id,'plan_id'=>$plan->id,'type'=>1,'period'=>'monthly','trade_no'=>'PUBLIC_NEGATIVE_ORDER','total_amount'=>-1,'status'=>1]);
    (new App\Jobs\OrderHandleJob($bad->trade_no))->handle(); $bad->refresh(); $badUser->refresh();
    fixtureCheck((int)$bad->status===1 && $badUser->plan_id===null && $db->table('v2_billing_review')->where('order_id',$bad->id)->count()===1,'historical_negative_processing_no_open');
    $fbUser=$makeUser('fubei'); $fbOrder=App\Services\OrderService::createFromRequest($fbUser,$plan,'monthly');
    fixtureCheck($request('/fixture/checkout',['trade_no'=>$fbOrder->trade_no,'method'=>$fubeiPayment->id],$fbUser)->getStatusCode()===200,'fubei_checkout_real_service_stub_transport');
    $attempt=$db->table('v2_payment_attempt')->where('order_id',$fbOrder->id)->first();
    fixtureCheck($attempt!==null && strlen($attempt->external_no)===32,'fubei_attempt_eloquent_mapping');
    $notification=['result_code'=>'200','result_message'=>'PUBLIC_FIXTURE','data'=>json_encode(['merchant_order_sn'=>$attempt->external_no,'order_sn'=>'PUBLIC_FB_CALLBACK','order_status'=>'SUCCESS','uid'=>123,'store_id'=>456,'pay_type'=>'wxpay','total_amount'=>'100.00'])];
    $notification['sign']=Plugin\Fubei\Signature::sign($notification,'public-fixture-not-a-credential');
    $raw=http_build_query($notification,'','&',PHP_QUERY_RFC3986);
    fixtureCheck($request('/api/v1/guest/payment/notify/Fubei/PUBLIC_FUBEI',$notification,null,$raw)->getStatusCode()===200,'fubei_raw_form_signature_through_kernel');
    fixtureCheck($request('/api/v1/guest/payment/notify/Fubei/PUBLIC_FUBEI',$notification,null,$raw)->getStatusCode()===200,'fubei_duplicate_callback_kernel'); $fbOrder->refresh();
    fixtureCheck((int)$fbOrder->status===3 && $db->table('fixture_consumer')->where('order_id',$fbOrder->id)->count()===1,'fubei_open_and_event_once');
    fixtureCheck($pdo===$db->getPdo() && $db->getDatabaseName()===$temporary.'/fixture.sqlite','same_isolated_connection');
    foreach ($hashes as $path=>$digest) fixtureCheck(!is_link($path) && hash_file('sha256',$path)===$digest,'source_unchanged_'.basename($path));
    $db->disconnect(); fixtureRemove($temporary);
    fixtureCheck(!file_exists($temporary),'fixture_work_removed'); $temporary=null;
    ob_end_clean();
    echo json_encode(['ok'=>true,'mode'=>'laravel_kernel_eloquent_file_sqlite','checks'=>$checks,'source_hashes'=>$hashes,'environment_loaded'=>false,'production_database_loaded'=>false,'stubs'=>['request_user_resolver','plugin_directory_discovery','legacy_gateway_verification','gateway_network_transport'],'real_paths'=>['http_kernel_and_api_middleware','application_exception_handler','payment_service','eloquent','order_service','sync_order_job','traffic_reset','commission_console_command','order_compensation_command','hook_manager','outbox'],'concurrency'=>'独立PDO多进程由另一fixture验收，本脚本只验收框架串行集成','external_payment'=>'未验收'],JSON_UNESCAPED_UNICODE).PHP_EOL;
} catch (Throwable $error) {
    while (ob_get_level()>0) ob_end_clean();
    echo json_encode(['ok'=>false,'stage'=>$stage,'exception_class'=>get_class($error),'exception_file'=>basename($error->getFile()),'exception_line'=>$error->getLine(),'http_witness'=>$GLOBALS['fixture_http_witness']??[],'checks'=>$checks,'temporary_retained_for_executor_cleanup'=>$temporary!==null],JSON_UNESCAPED_UNICODE).PHP_EOL;
    exit(1);
}
