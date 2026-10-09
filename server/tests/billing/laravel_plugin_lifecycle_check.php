<?php
/** 真实管理器生命周期；只操作唯一临时应用的目录及空插件表。 */
function fixturePluginLifecycle($db, string $candidate, string $temporary, $app): void
{
    $db->statement('CREATE TABLE v2_plugins(id INTEGER PRIMARY KEY AUTOINCREMENT,code TEXT UNIQUE,name TEXT,version TEXT,type TEXT,is_enabled INTEGER DEFAULT 0,config TEXT,installed_at TEXT,created_at TEXT,updated_at TEXT)');
    $directory=$temporary.'/plugins/Fubei';
    if (!mkdir($directory,0700)) throw new RuntimeException('临时插件目录创建失败');
    foreach (['config.json','Plugin.php','Amount.php','Client.php','JsonAmount.php','Notification.php','RawNotification.php','Signature.php'] as $name) {
        $source=fixtureFile($candidate,'server/plugins/Fubei/'.$name);
        if (!copy($source,$directory.'/'.$name) || hash_file('sha256',$source)!==hash_file('sha256',$directory.'/'.$name)) {
            throw new RuntimeException('临时插件公开副本核验失败');
        }
    }
    fixtureCheck(!class_exists(Plugin\Fubei\Plugin::class,false),'plugin_not_preloaded');
    $manager=new App\Services\Plugin\PluginManager();
    $app->instance(App\Services\Plugin\PluginManager::class,$manager);
    fixtureCheck($manager->getPluginPath('fubei')===$directory && !$manager->isCorePlugin('fubei'),'plugin_real_path_resolved');
    $installed=$manager->install('fubei');
    $row=App\Models\Plugin::where('code','fubei')->first();
    foreach (['returned'=>$installed,'row_found'=>$row!==null,'disabled'=>$row && !$row->is_enabled,
        'default_false'=>$row && (json_decode($row->config,true)['enabled']??null)===false] as $label=>$valid) {
        if (!$valid) fixtureCheck(false,'plugin_install_'.$label.'_failed');
    }
    fixtureCheck($installed && $row && !$row->is_enabled && json_decode($row->config,true)['enabled']===false,'plugin_install_disabled');
    $manager->enable('fubei');
    fixtureCheck(App\Models\Plugin::where('code','fubei')->first()->is_enabled
        && !isset(App\Services\Plugin\HookManager::filter('available_payment_methods',[])['Fubei']),'plugin_global_switch_off');
    $row->update(['config'=>json_encode(['enabled'=>true],JSON_THROW_ON_ERROR)]);
    $manager->enable('fubei');
    $catalog=App\Services\Plugin\HookManager::filter('available_payment_methods',[]);
    fixtureCheck(($catalog['Fubei']['plugin_code']??null)==='fubei','plugin_catalog_real_code');
    $plugins=$manager->getEnabledPaymentPlugins();
    fixtureCheck(count($plugins)===1 && isset($plugins['fubei']) && get_class($plugins['fubei'])===Plugin\Fubei\Plugin::class,'plugin_enabled_real_instance');
    $real=$plugins['fubei'];
    fixtureCheck($real->getBasePath()===$directory
        && (new ReflectionClass($real))->getFileName()===$directory.'/Plugin.php'
        && hash_file('sha256',$directory.'/Plugin.php')===hash_file('sha256',fixtureFile($candidate,'server/plugins/Fubei/Plugin.php')),'plugin_dynamic_file_loaded');
    $db->beginTransaction();
    $payment=App\Models\Payment::create(['uuid'=>'public-plugin-entry','payment'=>'Fubei','name'=>'公开关闭方式',
        'config'=>['enabled'=>true,'identity_mode'=>'merchant','app_id'=>'public_plugin_entry','vendor_sn'=>'',
            'merchant_id'=>'11','store_id'=>'22','secret_ref'=>'public_missing_reference',
            'gateway'=>'https://gateway.example.test/openapi','gateway_hosts'=>'gateway.example.test',
            'payment_hosts'=>'pay.example.test','notify_hosts'=>'fixture.example.test','expired_time'=>'900'],
        'enable'=>false,'notify_domain'=>'']);
    $service=new App\Services\PaymentService('Fubei',$payment->id);
    $property=new ReflectionProperty(App\Services\PaymentService::class,'payment');
    $property->setAccessible(true);
    fixtureCheck($property->getValue($service)===$real && $real->getPluginCode()==='fubei','plugin_payment_service_selected');
    fixtureCheck($real->getConfig('id')===$payment->id && $real->getConfig('uuid')===$payment->uuid
        && $real->getConfig('enable')===false && $real->getConfig('app_id')==='public_plugin_entry','plugin_payment_config_injected');
    $form=$service->form();
    fixtureCheck(($form['app_id']['value']??null)==='public_plugin_entry'
        && ($form['expired_time']['value']??null)==='900'
        && ($form['secret_ref']['value']??null)==='public_missing_reference' && !isset($form['app_secret']),'plugin_payment_form_values');
    $byUuid=new App\Services\PaymentService('Fubei',null,$payment->uuid);
    fixtureCheck($property->getValue($byUuid)===$real,'plugin_payment_uuid_selected');
    $beforeAttempts=$db->table('v2_payment_attempt')->count();
    $beforeGateway=$db->table('fixture_gateway')->count();
    // 同一有效订单/快照用于关闭及开启对照；故意缺席的公开密钥引用在创建尝试后、网络前失败。
    fixtureCheck(config('payments.fubei.secrets.public_missing_reference')===null,'plugin_payment_control_secret_absent');
    $order=App\Models\Order::create(['user_id'=>1,'plan_id'=>1,'payment_id'=>$payment->id,
        'trade_no'=>'public-disabled-order','total_amount'=>100,'handling_amount'=>0,'status'=>0]);
    $payload=['trade_no'=>$order->trade_no,'total_amount'=>100,'user_id'=>1,'stripe_token'=>null];
    $rejected=0;
    foreach ([$service,$byUuid] as $entry) {
        try {
            $entry->pay($payload);
        } catch (App\Exceptions\ApiException $e) {
            $rejected++;
        }
    }
    fixtureCheck($rejected===2,'plugin_payment_disabled_rejected');
    fixtureCheck($db->table('v2_payment_attempt')->count()===$beforeAttempts
        && $db->table('fixture_gateway')->count()===$beforeGateway,'plugin_payment_no_effect');
    $payment->update(['enable'=>true]);
    $opened=new App\Services\PaymentService('Fubei',$payment->id);
    try { $opened->pay($payload); } catch (App\Exceptions\ApiException $e) {}
    $attempt=$db->table('v2_payment_attempt')->where('order_id',$order->id)->first();
    fixtureCheck($db->table('v2_payment_attempt')->count()===$beforeAttempts+1 && $attempt
        && (int)$attempt->expected_cents===100 && (int)$attempt->payment_id===$payment->id
        && $db->table('fixture_gateway')->count()===$beforeGateway,'plugin_payment_enabled_attempt_control');
    $db->rollBack();
    fixtureCheck(App\Models\Payment::count()===0 && App\Models\Order::count()===0
        && $db->table('v2_payment_attempt')->count()===$beforeAttempts,'plugin_payment_row_removed');
    $manager->disable('fubei');
    fixtureCheck(!$row->fresh()->is_enabled && $manager->getEnabledPaymentPlugins()===[],'plugin_disabled_discovery_empty');
    // 显式重建请求的Hook容器；同请求旧闭包是否残留不属于新请求目录发现证据。
    $app->instance('hook.filters',[]);
    $fresh=new App\Services\Plugin\PluginManager();
    $fresh->initializeEnabledPlugins();
    fixtureCheck(App\Services\Plugin\HookManager::filter('available_payment_methods',[])===[],'plugin_disabled_fresh_catalog_empty');
    $manager->uninstall('fubei');
    fixtureCheck(!App\Models\Plugin::where('code','fubei')->exists(),'plugin_uninstalled_row_removed');
    $app->instance('hook.filters',[]);
}
