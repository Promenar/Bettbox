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
