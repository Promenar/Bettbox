// 业务回包只接受当前探针合同，不输出原始载荷。
bool acceptsProbeResult(Object? value, int generation) {
  const keys = {'id', 'method', 'data', 'code', 'Port'};
  return value is Map &&
      value.length == keys.length &&
      value.keys.every(keys.contains) &&
      value['id'] == 'g$generation-r1' &&
      value['method'] == 'getIsInit' &&
      value['data'] == false &&
      value['code'] is int &&
      value['code'] == 0 &&
      value['Port'] is int &&
      value['Port'] == 0;
}
