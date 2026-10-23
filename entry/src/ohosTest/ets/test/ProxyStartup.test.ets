import { abilityDelegatorRegistry } from '@kit.TestKit';
import { fileIo } from '@kit.CoreFileKit';
import { describe, it, expect } from '@ohos/hypium';
import { MihomoCore, CoreOpResult } from '../../../main/ets/mihomo/MihomoCore';

// Run with tools/mihomo/slow-rule-server.py and hdc rport tcp:18080 tcp:18080.
// The eight-second rule response deliberately exceeds the UI watchdog threshold.
export default function proxyStartupTest() {
  describe('ProxyStartup', () => {
    it('slowRuleDownloadKeepsEventLoopResponsive', 0, async () => {
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      expect(MihomoCore.load(context.bundleCodeDir, context.filesDir).ok).assertTrue();
      const rulePath: string = context.filesDir + '/startup-regression-rules.yaml';
      if (fileIo.accessSync(rulePath)) { fileIo.unlinkSync(rulePath); }
      const configPath: string = context.filesDir + '/startup-regression.yaml';
      const config: string = 'mixed-port: 17890\nallow-lan: false\nbind-address: 127.0.0.1\n' +
        'mode: rule\nproxies: []\nproxy-groups: []\nrule-providers:\n' +
        '  slow:\n    type: http\n    behavior: domain\n    format: yaml\n' +
        '    url: http://127.0.0.1:18080/slow.yaml\n    path: ' + rulePath + '\n' +
        'rules:\n  - RULE-SET,slow,DIRECT\n  - MATCH,DIRECT\n';
      const configFile = fileIo.openSync(configPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      try { fileIo.writeSync(configFile.fd, config); } finally { fileIo.closeSync(configFile); }
      let ticks: number = 0;
      let largestGap: number = 0;
      let previousTick: number = Date.now();
      const timer: number = setInterval(() => {
        const now: number = Date.now();
        largestGap = Math.max(largestGap, now - previousTick);
        previousTick = now;
        ticks++;
      }, 100);
      const began: number = Date.now();
      let result: CoreOpResult;
      try {
        result = await MihomoCore.start(configPath);
      } finally {
        largestGap = Math.max(largestGap, Date.now() - previousTick);
        clearInterval(timer);
      }
      const elapsed: number = Date.now() - began;
      const stopped: CoreOpResult = MihomoCore.stop();
      console.info('ProxyStartupRegression elapsedMs=' + elapsed.toString() +
        ' ticks=' + ticks.toString() + ' largestGapMs=' + largestGap.toString());
      expect(result.ok).assertTrue();
      expect(stopped.ok).assertTrue();
      expect(elapsed >= 7000).assertTrue();
      expect(ticks >= 20).assertTrue();
      expect(largestGap < 2000).assertTrue();
      fileIo.unlinkSync(configPath);
      if (fileIo.accessSync(rulePath)) { fileIo.unlinkSync(rulePath); }
    });

    it('missingConfigReturnsFailure', 0, async () => {
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      const result: CoreOpResult = await MihomoCore.start(context.filesDir + '/missing-regression.yaml');
      expect(result.ok).assertFalse();
    });

    it('cancelAndRejectOverlappingStartup', 0, async () => {
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      const configPath: string = context.filesDir + '/startup-cancel-regression.yaml';
      const configFile = fileIo.openSync(configPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(configFile.fd, 'mixed-port: 17891\nmode: direct\nproxies: []\n');
      } finally { fileIo.closeSync(configFile); }
      const pending: Promise<CoreOpResult> = MihomoCore.start(configPath);
      const overlapping: Promise<CoreOpResult> = MihomoCore.start(configPath);
      expect(MihomoCore.stop().ok).assertTrue();
      const result: CoreOpResult = await pending;
      const duplicate: CoreOpResult = await overlapping;
      expect(result.ok).assertFalse();
      expect(duplicate.ok).assertFalse();
      expect(MihomoCore.status().running).assertEqual(0);
      fileIo.unlinkSync(configPath);
    });
  });
}
