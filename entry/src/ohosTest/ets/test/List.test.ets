import abilityTest from './Ability.test';
import proxyStartupTest from './ProxyStartup.test';

export default function testsuite() {
  abilityTest();
  proxyStartupTest();
}
