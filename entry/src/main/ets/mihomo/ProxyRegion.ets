/**
 * 节点地区识别与 ChatGPT 可用地区排序。
 *
 * 为什么需要：
 *   ChatGPT 只在部分国家和地区提供服务，香港、澳门、中国大陆、俄罗斯等地区会被拒绝。
 *   而订阅里的节点是按延迟排序选出来的 —— 香港节点物理距离最近、延迟最低，
 *   于是自动选路几乎必然选中一个"能用代理、但 ChatGPT 打不开"的出口。
 *   真机日志已经复现过：104 个节点测速后选中的是「V香港 07」。
 *
 * 做法：
 *   从节点名里识别地区（中文关键词 / 国家旗帜 emoji / 大写的两三位国家代码），
 *   分成若干优先级：日本 > 新加坡 > 美国 > 其它可用地区 > 未知 > 不可用地区。
 *   AutoSelect 先按优先级排序再测速，于是有限的时间预算优先花在可用的地区上。
 *
 * 为什么靠名字而不是 IP 库：
 *   1) 节点名是订阅方唯一稳定提供的元信息，IP 库要额外几十 MB 且需要联网更新；
 *   2) 机场的命名习惯高度一致（"V日本 01"、"🇸🇬 新加坡 02"、"US-Los Angeles"），
 *      关键词覆盖足够；
 *   3) 识别不出来时落到 UNKNOWN —— 仍然排在"明确不可用地区"之前，
 *      不会因为词表不全而把好节点排除掉。
 *   代价是伪装成"日本"的香港节点识别不出来，但那是订阅方标注错误，无从校验。
 *
 * 【为什么每个可用国家要单独一条规则，而不是共用一个 SUPPORTED 大桶】
 * 早先所有可用国家（台湾、德国、巴西……）挤在一条规则里，label 是空串，
 * 于是它们全都显示成"未知地区"，也无法按国家拆分策略组。
 * 用户要求"负载均衡里能选每一个国家"，就必须知道节点到底属于哪个国家，
 * 所以这里把每个国家拆成独立规则，各自带自己的 label。
 * 优先级仍然是同一个 SUPPORTED 档，拆分不改变选路顺序。
 */

import { ParsedNode } from './SubscriptionLoader';

/** 地区优先级：数字越小越优先。 */
export enum RegionTier {
  JAPAN = 0,
  SINGAPORE = 1,
  UNITED_STATES = 2,
  SUPPORTED = 3,
  UNKNOWN = 4,
  BLOCKED = 5
}

export interface RegionInfo {
  tier: number;
  /** 展示用地区名；识别不出为空串 */
  label: string;
  /** 两位国家代码（JP/SG/US…）；识别不出为空串 */
  code: string;
}

interface RegionRule {
  tier: number;
  label: string;
  /** 两位国家代码（JP/SG/US…），用于显示成「JP 日本」这样中英并列的名字 */
  code: string;
  /** 中文/英文关键词，按小写比较 */
  words: string[];
  /** 国旗 emoji */
  flags: string[];
  /** 国家/地区代码的正则片段（要求独立成词）；空串表示这条规则不匹配代码 */
  codePattern: string;
}

/** 一个国家的节点集合（用于按国家生成负载均衡组）。 */
export interface CountryPool {
  /** 展示名，例如「日本」「新加坡」；识别不出时为「未知地区」 */
  label: string;
  /** 两位国家代码（JP/SG/US…）；识别不出为空串 */
  code: string;
  /** 该国家的节点名，按订阅原顺序 */
  nodes: string[];
  /** 地区优先级，用于排序（日本在前） */
  tier: number;
}

// ---------------------------------------------------------------------------
// 高优先级地区
// ---------------------------------------------------------------------------

const JAPAN_RULE: RegionRule = {
  tier: RegionTier.JAPAN, label: '日本', code: 'JP',
  words: ['日本', '东京', '東京', '大阪', '京都', '名古屋', '札幌', '埼玉', '福冈', '福岡',
    '横滨', '橫濱', '神户', '神戶', 'japan', 'tokyo', 'osaka', 'kyoto', 'nagoya', 'sapporo'],
  flags: ['🇯🇵'],
  codePattern: '(^|[^A-Za-z])(JP|JPN)([^A-Za-z]|$)'
};

const SINGAPORE_RULE: RegionRule = {
  tier: RegionTier.SINGAPORE, label: '新加坡', code: 'SG',
  words: ['新加坡', '狮城', '獅城', 'singapore'],
  flags: ['🇸🇬'],
  codePattern: '(^|[^A-Za-z])(SGP|SG)([^A-Za-z]|$)'
};

const UNITED_STATES_RULE: RegionRule = {
  tier: RegionTier.UNITED_STATES, label: '美国', code: 'US',
  words: ['美国', '美國', '洛杉矶', '洛杉磯', '圣何塞', '聖何塞', '西雅图', '西雅圖',
    '纽约', '紐約', '达拉斯', '達拉斯', '芝加哥', '迈阿密', '邁阿密', '硅谷', '矽谷',
    '凤凰城', '鳳凰城', '阿什本', '波特兰', '波特蘭', '亚特兰大', '亞特蘭大',
    '波士顿', '波士頓', '华盛顿', '華盛頓', 'united states', 'america', 'los angeles',
    'san jose', 'seattle', 'new york', 'dallas', 'chicago', 'miami', 'silicon valley',
    'phoenix', 'ashburn', 'portland', 'atlanta', 'boston'],
  flags: ['🇺🇸'],
  codePattern: '(^|[^A-Za-z])(USA|US)([^A-Za-z]|$)'
};

// ---------------------------------------------------------------------------
// 其它 ChatGPT 可用国家
//
// 【顺序是有语义的】规则按数组顺序逐条匹配，先命中先返回，所以：
//   · 印度尼西亚必须排在印度前面，否则「印度尼西亚」会被「印度」抢先匹配；
//   · 罗马尼亚必须排在阿曼前面，因为 "romania" 里含有 "oman"；
//   · 同时出现在两个国家词表里的地名（如「圣何塞」）由更靠前的规则拿走，
//     这里已经是美国优先，故哥斯达黎加不再重复列出该中文名。
// 新增国家时请插在合适位置，并确认没有更短的同名子串被前面的国家吃掉。
// ---------------------------------------------------------------------------
const SUPPORTED_COUNTRIES: RegionRule[] = [
  {
    tier: RegionTier.SUPPORTED, label: '台湾', code: 'TW',
    words: ['台湾', '台灣', '臺灣', '台北', '新北', '台中', '高雄', 'taiwan', 'taipei'],
    flags: ['🇹🇼'], codePattern: '(^|[^A-Za-z])(TW)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '韩国', code: 'KR',
    words: ['韩国', '韓國', '首尔', '首爾', '釜山', 'korea', 'seoul', 'busan'],
    flags: ['🇰🇷'], codePattern: '(^|[^A-Za-z])(KOR|KR)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '加拿大', code: 'CA',
    words: ['加拿大', '多伦多', '温哥华', '溫哥華', '蒙特利尔', '蒙特婁', 'canada', 'toronto', 'vancouver'],
    flags: ['🇨🇦'], codePattern: '(^|[^A-Za-z])(CA|CAN)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '英国', code: 'GB',
    words: ['英国', '英國', '伦敦', '倫敦', 'england', 'britain', 'united kingdom', 'london'],
    flags: ['🇬🇧'], codePattern: '(^|[^A-Za-z])(UK|GB)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '德国', code: 'DE',
    words: ['德国', '德國', '法兰克福', '法蘭克福', '柏林', '慕尼黑', 'germany', 'frankfurt', 'berlin'],
    flags: ['🇩🇪'], codePattern: '(^|[^A-Za-z])(DEU|DE)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '法国', code: 'FR',
    words: ['法国', '法國', '巴黎', 'france', 'paris'],
    flags: ['🇫🇷'], codePattern: '(^|[^A-Za-z])(FRA|FR)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '荷兰', code: 'NL',
    words: ['荷兰', '荷蘭', '阿姆斯特丹', 'netherlands', 'amsterdam'],
    flags: ['🇳🇱'], codePattern: '(^|[^A-Za-z])(NLD|NL)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '澳大利亚', code: 'AU',
    words: ['澳大利亚', '澳洲', '悉尼', '雪梨', '墨尔本', '墨爾本', 'australia', 'sydney', 'melbourne'],
    flags: ['🇦🇺'], codePattern: '(^|[^A-Za-z])(AUS|AU)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '新西兰', code: 'NZ',
    words: ['新西兰', '紐西蘭', '奥克兰', '奧克蘭', 'new zealand', 'auckland'],
    flags: ['🇳🇿'], codePattern: '(^|[^A-Za-z])(NZL|NZ)([^A-Za-z]|$)'
  },
  // 必须排在「印度」之前：否则「印度尼西亚」会被「印度」先命中。
  {
    tier: RegionTier.SUPPORTED, label: '印度尼西亚', code: 'ID',
    words: ['印度尼西亚', '印尼', '雅加达', '雅加達', 'indonesia', 'jakarta'],
    flags: ['🇮🇩'], codePattern: '(^|[^A-Za-z])(IDN)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '印度', code: 'IN',
    words: ['印度', 'india', 'mumbai', '孟买', '孟買'],
    flags: ['🇮🇳'], codePattern: '(^|[^A-Za-z])(IND)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '巴西', code: 'BR',
    words: ['巴西', '圣保罗', '聖保羅', 'brazil', 'sao paulo'],
    flags: ['🇧🇷'], codePattern: '(^|[^A-Za-z])(BRA|BR)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '墨西哥', code: 'MX',
    words: ['墨西哥', 'mexico'],
    flags: ['🇲🇽'], codePattern: '(^|[^A-Za-z])(MEX|MX)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '阿根廷', code: 'AR',
    words: ['阿根廷', 'argentina'],
    flags: ['🇦🇷'], codePattern: '(^|[^A-Za-z])(ARG)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '智利', code: 'CL',
    words: ['智利', 'chile'],
    flags: ['🇨🇱'], codePattern: '(^|[^A-Za-z])(CHL|CL)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '哥伦比亚', code: 'CO',
    words: ['哥伦比亚', '哥倫比亞', 'colombia'],
    flags: ['🇨🇴'], codePattern: '(^|[^A-Za-z])(CO|COL)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '爱尔兰', code: 'IE',
    words: ['爱尔兰', '愛爾蘭', '都柏林', 'ireland', 'dublin'],
    flags: ['🇮🇪'], codePattern: '(^|[^A-Za-z])(IRL|IE)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '意大利', code: 'IT',
    words: ['意大利', '義大利', '米兰', '米蘭', 'italy', 'milan'],
    flags: ['🇮🇹'], codePattern: '(^|[^A-Za-z])(ITA|IT)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '西班牙', code: 'ES',
    words: ['西班牙', '马德里', '馬德里', 'spain', 'madrid', 'barcelona'],
    flags: ['🇪🇸'], codePattern: '(^|[^A-Za-z])(ESP|ES)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '葡萄牙', code: 'PT',
    words: ['葡萄牙', '里斯本', 'portugal', 'lisbon'],
    flags: ['🇵🇹'], codePattern: '(^|[^A-Za-z])(PRT|PT)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '波兰', code: 'PL',
    words: ['波兰', '波蘭', '华沙', '華沙', 'poland', 'warsaw'],
    flags: ['🇵🇱'], codePattern: '(^|[^A-Za-z])(POL|PL)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '捷克', code: 'CZ',
    words: ['捷克', '布拉格', 'czech', 'prague'],
    flags: ['🇨🇿'], codePattern: '(^|[^A-Za-z])(CZE|CZ)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '奥地利', code: 'AT',
    words: ['奥地利', '奧地利', '维也纳', '維也納', 'austria', 'vienna'],
    flags: ['🇦🇹'], codePattern: '(^|[^A-Za-z])(AUT|AT)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '瑞典', code: 'SE',
    words: ['瑞典', '斯德哥尔摩', '斯德哥爾摩', 'sweden', 'stockholm'],
    flags: ['🇸🇪'], codePattern: '(^|[^A-Za-z])(SWE|SE)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '挪威', code: 'NO',
    words: ['挪威', '奥斯陆', '奧斯陸', 'norway', 'oslo'],
    flags: ['🇳🇴'], codePattern: '(^|[^A-Za-z])(NOR)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '丹麦', code: 'DK',
    words: ['丹麦', '丹麥', '哥本哈根', 'denmark', 'copenhagen'],
    flags: ['🇩🇰'], codePattern: '(^|[^A-Za-z])(DNK|DK)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '芬兰', code: 'FI',
    words: ['芬兰', '芬蘭', '赫尔辛基', '赫爾辛基', 'finland', 'helsinki'],
    flags: ['🇫🇮'], codePattern: '(^|[^A-Za-z])(FIN|FI)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '瑞士', code: 'CH',
    words: ['瑞士', '苏黎世', '蘇黎世', 'switzerland', 'zurich'],
    flags: ['🇨🇭'], codePattern: '(^|[^A-Za-z])(CHE|CH)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '比利时', code: 'BE',
    words: ['比利时', '比利時', '布鲁塞尔', '布魯塞爾', 'belgium', 'brussels'],
    flags: ['🇧🇪'], codePattern: '(^|[^A-Za-z])(BEL|BE)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '以色列', code: 'IL',
    words: ['以色列', '特拉维夫', '特拉維夫', 'israel', 'tel aviv'],
    flags: ['🇮🇱'], codePattern: '(^|[^A-Za-z])(ISR|IL)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '阿联酋', code: 'AE',
    words: ['阿联酋', '阿聯酋', '迪拜', 'uae', 'dubai'],
    flags: ['🇦🇪'], codePattern: '(^|[^A-Za-z])(ARE|AE)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '土耳其', code: 'TR',
    words: ['土耳其', '伊斯坦布尔', '伊斯坦堡', 'turkey', 'istanbul'],
    flags: ['🇹🇷'], codePattern: '(^|[^A-Za-z])(TUR|TR)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '南非', code: 'ZA',
    words: ['南非', 'south africa'],
    flags: ['🇿🇦'], codePattern: '(^|[^A-Za-z])(ZAF|ZA)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '泰国', code: 'TH',
    words: ['泰国', '泰國', '曼谷', 'thailand', 'bangkok'],
    flags: ['🇹🇭'], codePattern: '(^|[^A-Za-z])(THA|TH)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '马来西亚', code: 'MY',
    words: ['马来西亚', '馬來西亞', '吉隆坡', 'malaysia', 'kuala lumpur'],
    flags: ['🇲🇾'], codePattern: '(^|[^A-Za-z])(MYS|MY)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '越南', code: 'VN',
    words: ['越南', 'vietnam', 'hanoi', '河内', '河內'],
    flags: ['🇻🇳'], codePattern: '(^|[^A-Za-z])(VNM|VN)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '菲律宾', code: 'PH',
    words: ['菲律宾', '菲律賓', '马尼拉', '馬尼拉', 'philippines', 'manila'],
    flags: ['🇵🇭'], codePattern: '(^|[^A-Za-z])(PHL|PH)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '乌克兰', code: 'UA',
    words: ['乌克兰', '烏克蘭', 'ukraine'],
    flags: ['🇺🇦'], codePattern: '(^|[^A-Za-z])(UKR|UA)([^A-Za-z]|$)'
  },
  // 必须排在「阿曼」之前：'romania' 里含有 'oman'，否则罗马尼亚会被判成阿曼。
  {
    tier: RegionTier.SUPPORTED, label: '罗马尼亚', code: 'RO',
    words: ['罗马尼亚', '羅馬尼亞', 'romania'],
    flags: ['🇷🇴'], codePattern: '(^|[^A-Za-z])(ROU|RO)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '匈牙利', code: 'HU',
    words: ['匈牙利', '布达佩斯', '布達佩斯', 'hungary', 'budapest'],
    flags: ['🇭🇺'], codePattern: '(^|[^A-Za-z])(HUN|HU)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '保加利亚', code: 'BG',
    words: ['保加利亚', '保加利亞', 'bulgaria'],
    flags: ['🇧🇬'], codePattern: '(^|[^A-Za-z])(BGR|BG)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '希腊', code: 'GR',
    words: ['希腊', '希臘', 'greece', 'athens', '雅典'],
    flags: ['🇬🇷'], codePattern: '(^|[^A-Za-z])(GRC|GR)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '克罗地亚', code: 'HR',
    words: ['克罗地亚', '克羅埃西亞', 'croatia'],
    flags: ['🇭🇷'], codePattern: '(^|[^A-Za-z])(HRV|HR)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '斯洛伐克', code: 'SK',
    words: ['斯洛伐克', 'slovakia'],
    flags: ['🇸🇰'], codePattern: '(^|[^A-Za-z])(SVK|SK)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '斯洛文尼亚', code: 'SI',
    words: ['斯洛文尼亚', 'slovenia'],
    flags: ['🇸🇮'], codePattern: '(^|[^A-Za-z])(SVN|SI)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '立陶宛', code: 'LT',
    words: ['立陶宛', 'lithuania'],
    flags: ['🇱🇹'], codePattern: '(^|[^A-Za-z])(LTU|LT)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '拉脱维亚', code: 'LV',
    words: ['拉脱维亚', '拉脫維亞', 'latvia'],
    flags: ['🇱🇻'], codePattern: '(^|[^A-Za-z])(LVA|LV)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '爱沙尼亚', code: 'EE',
    words: ['爱沙尼亚', '愛沙尼亞', 'estonia'],
    flags: ['🇪🇪'], codePattern: '(^|[^A-Za-z])(EST|EE)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '塞尔维亚', code: 'RS',
    words: ['塞尔维亚', '塞爾維亞', 'serbia'],
    flags: ['🇷🇸'], codePattern: '(^|[^A-Za-z])(SRB|RS)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '冰岛', code: 'IS',
    words: ['冰岛', '冰島', 'iceland'],
    flags: ['🇮🇸'], codePattern: '(^|[^A-Za-z])(ISL|IS)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '卢森堡', code: 'LU',
    words: ['卢森堡', 'luxembourg'],
    flags: ['🇱🇺'], codePattern: '(^|[^A-Za-z])(LUX|LU)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '马耳他', code: 'MT',
    words: ['马耳他', '馬爾他', 'malta'],
    flags: ['🇲🇹'], codePattern: '(^|[^A-Za-z])(MLT|MT)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '塞浦路斯', code: 'CY',
    words: ['塞浦路斯', 'cyprus'],
    flags: ['🇨🇾'], codePattern: '(^|[^A-Za-z])(CYP|CY)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '沙特', code: 'SA',
    words: ['沙特', '沙烏地', 'saudi'],
    flags: ['🇸🇦'], codePattern: '(^|[^A-Za-z])(SAU|SA)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '卡塔尔', code: 'QA',
    words: ['卡塔尔', '卡達', 'qatar'],
    flags: ['🇶🇦'], codePattern: '(^|[^A-Za-z])(QAT|QA)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '科威特', code: 'KW',
    words: ['科威特', 'kuwait'],
    flags: ['🇰🇼'], codePattern: '(^|[^A-Za-z])(KWT|KW)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '巴林', code: 'BH',
    words: ['巴林', 'bahrain'],
    flags: ['🇧🇭'], codePattern: '(^|[^A-Za-z])(BHR|BH)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '约旦', code: 'JO',
    words: ['约旦', '約旦', 'jordan'],
    flags: ['🇯🇴'], codePattern: '(^|[^A-Za-z])(JOR|JO)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '埃及', code: 'EG',
    words: ['埃及', 'egypt'],
    flags: ['🇪🇬'], codePattern: '(^|[^A-Za-z])(EGY|EG)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '肯尼亚', code: 'KE',
    words: ['肯尼亚', '肯亞', 'kenya'],
    flags: ['🇰🇪'], codePattern: '(^|[^A-Za-z])(KEN|KE)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '尼日利亚', code: 'NG',
    words: ['尼日利亚', '奈及利亞', 'nigeria'],
    flags: ['🇳🇬'], codePattern: '(^|[^A-Za-z])(NGA|NG)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '摩洛哥', code: 'MA',
    words: ['摩洛哥', 'morocco'],
    flags: ['🇲🇦'], codePattern: '(^|[^A-Za-z])(MAR|MA)([^A-Za-z]|$)'
  },
  // 小国/冷门地区：机场订阅里出现频率不高，但漏掉就会被归到"未知"，
  // 进而失去优先测速机会（未知排在可用地区之后）。
  // 这些只收三位代码，避免两位代码在节点名里和普通英文词撞车。
  {
    tier: RegionTier.SUPPORTED, label: '柬埔寨', code: 'KH',
    words: ['柬埔寨', 'cambodia', 'phnom penh', '金边', '金邊'],
    flags: ['🇰🇭'], codePattern: '(^|[^A-Za-z])(KHM)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '孟加拉', code: 'BD',
    words: ['孟加拉', 'bangladesh', 'dhaka', '达卡', '達卡'],
    flags: ['🇧🇩'], codePattern: '(^|[^A-Za-z])(BGD)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '尼泊尔', code: 'NP',
    words: ['尼泊尔', '尼泊爾', 'nepal', 'kathmandu', '加德满都', '加德滿都'],
    flags: ['🇳🇵'], codePattern: '(^|[^A-Za-z])(NPL)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '北马其顿', code: 'MK',
    words: ['马其顿', '馬其頓', 'north macedonia', 'macedonia', 'skopje', '斯科普里'],
    flags: ['🇲🇰'], codePattern: '(^|[^A-Za-z])(MKD)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '阿尔巴尼亚', code: 'AL',
    words: ['阿尔巴尼亚', '阿爾巴尼亞', 'albania', 'tirana', '地拉那'],
    flags: ['🇦🇱'], codePattern: '(^|[^A-Za-z])(ALB)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '格鲁吉亚', code: 'GE',
    words: ['格鲁吉亚', '喬治亞', 'georgia', 'tbilisi', '第比利斯'],
    flags: ['🇬🇪'], codePattern: '(^|[^A-Za-z])(GEO)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '摩尔多瓦', code: 'MD',
    words: ['摩尔多瓦', '摩爾多瓦', 'moldova', 'chisinau', '基希讷乌', '基希訥烏'],
    flags: ['🇲🇩'], codePattern: '(^|[^A-Za-z])(MDA)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '安哥拉', code: 'AO',
    words: ['安哥拉', 'angola', 'luanda', '罗安达', '羅安達'],
    flags: ['🇦🇴'], codePattern: '(^|[^A-Za-z])(AGO)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '伊拉克', code: 'IQ',
    words: ['伊拉克', 'iraq', 'baghdad', '巴格达', '巴格達'],
    flags: ['🇮🇶'], codePattern: '(^|[^A-Za-z])(IRQ)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '阿曼', code: 'OM',
    words: ['阿曼', 'oman', 'muscat', '马斯喀特', '馬斯喀特'],
    flags: ['🇴🇲'], codePattern: '(^|[^A-Za-z])(OMN)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '巴基斯坦', code: 'PK',
    words: ['巴基斯坦', 'pakistan', 'karachi', 'karāchi', 'islamabad', '伊斯兰堡', '伊斯蘭堡'],
    flags: ['🇵🇰'], codePattern: '(^|[^A-Za-z])(PAK)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '乌兹别克斯坦', code: 'UZ',
    words: ['乌兹别克斯坦', '烏茲別克', 'uzbekistan', 'tashkent', '塔什干'],
    flags: ['🇺🇿'], codePattern: '(^|[^A-Za-z])(UZB)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '哈萨克斯坦', code: 'KZ',
    words: ['哈萨克斯坦', '哈薩克', 'kazakhstan', 'almaty', '阿拉木图', '阿拉木圖'],
    flags: ['🇰🇿'], codePattern: '(^|[^A-Za-z])(KAZ)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '秘鲁', code: 'PE',
    words: ['秘鲁', '秘魯', 'peru', 'lima', '利马', '利馬'],
    flags: ['🇵🇪'], codePattern: '(^|[^A-Za-z])(PER)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '厄瓜多尔', code: 'EC',
    words: ['厄瓜多尔', '厄瓜多', 'ecuador', 'quito', '基多'],
    flags: ['🇪🇨'], codePattern: '(^|[^A-Za-z])(ECU)([^A-Za-z]|$)'
  },
  // 只收 "costa rica" 与中文国名：'san jose' / '圣何塞' 同时是美国圣何塞，
  // 而美国规则排在前面，写在这里也永远轮不到，反而容易让人误以为已覆盖。
  {
    tier: RegionTier.SUPPORTED, label: '哥斯达黎加', code: 'CR',
    words: ['哥斯达黎加', '哥斯大黎加', 'costa rica'],
    flags: ['🇨🇷'], codePattern: '(^|[^A-Za-z])(CRI)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '玻利维亚', code: 'BO',
    words: ['玻利维亚', '玻利維亞', 'bolivia', 'la paz', '拉巴斯'],
    flags: ['🇧🇴'], codePattern: '(^|[^A-Za-z])(BOL)([^A-Za-z]|$)'
  },
  {
    tier: RegionTier.SUPPORTED, label: '乌拉圭', code: 'UY',
    words: ['乌拉圭', 'uruguay', 'montevideo', '蒙得维的亚', '蒙得維的亞'],
    flags: ['🇺🇾'], codePattern: '(^|[^A-Za-z])(URY)([^A-Za-z]|$)'
  }
];

const BLOCKED_RULE: RegionRule = {
  tier: RegionTier.BLOCKED, label: '不可用地区', code: '',
  words: ['香港', 'hong kong', 'hongkong',
    '澳门', '澳門', 'macau', 'macao',
    '中国', '中國', 'china', '大陆', '大陸', '国内', '國內',
    '深圳', '上海', '北京', '广州', '廣州', '杭州', '成都', '南京', '武汉', '武漢',
    '重庆', '重慶', '西安', '青岛', '青島', '苏州', '蘇州', '厦门', '廈門', '天津',
    '长沙', '長沙', '郑州', '鄭州', '合肥', '济南', '濟南', '福州', '昆明', '南昌',
    '贵阳', '貴陽', '南宁', '南寧', '海口', '三亚', '三亞',
    '俄罗斯', '俄羅斯', 'russia', 'moscow', '莫斯科', '圣彼得堡', '聖彼得堡',
    '伊朗', 'iran', 'tehran', '德黑兰', '德黑蘭',
    '朝鲜', '北韩', '北韓', 'north korea',
    '古巴', 'cuba',
    '叙利亚', '敘利亞', 'syria',
    '白俄罗斯', '白俄羅斯', 'belarus',
    '委内瑞拉', '委內瑞拉', 'venezuela',
    '缅甸', '緬甸', 'myanmar',
    '苏丹', '蘇丹', 'sudan'],
  flags: ['🇭🇰', '🇲🇴', '🇨🇳', '🇷🇺', '🇮🇷', '🇰🇵', '🇨🇺', '🇸🇾', '🇧🇾', '🇻🇪', '🇲🇲', '🇸🇩'],
  codePattern: '(^|[^A-Za-z])(HK|HKG|CN|CHN|RU|RUS|IR|IRN|KP|PRK|CU|CUB|SY|SYR|BY|BLR)([^A-Za-z]|$)'
};

/**
 * 规则按优先级排列，**顺序本身就是语义**：
 *   · 「美国 洛杉矶 | 香港中转」先命中"美国"——出口在 US，中转在哪不影响；
 *   · 「台湾 中转 香港」先命中 SUPPORTED 再看 BLOCKED，不会被中转地误判成香港；
 *   · 词表内部把长词放在短词前面（印度尼西亚 在 印度 之前），避免被短词抢先匹配。
 *
 * 代码匹配用「大写 + 独立成词」，避免 US 命中 RUS、JP 命中某个英文单词的片段。
 * 两条高风险的两位代码（NO=挪威、ID=印尼、MY=马来、IN=印度）刻意不收：
 * 在节点名里它们太容易和普通英文词撞车，这些地区改由中文名/全称覆盖。
 */
const RULES: RegionRule[] = [JAPAN_RULE, SINGAPORE_RULE, UNITED_STATES_RULE]
  .concat(SUPPORTED_COUNTRIES)
  .concat([BLOCKED_RULE]);

/** 预编译代码正则：每条规则只构造一次，避免每次分类都重新编译。 */
const CODE_PATTERNS: RegExp[] = RULES.map((rule: RegionRule) => new RegExp(rule.codePattern));

export class ProxyRegion {
  /**
   * 识别单个节点名的地区。
   * 规则顺序 = 优先级；识别不出返回 UNKNOWN（空标签），仍然可用。
   */
  static classify(name: string): RegionInfo {
    if (name.length === 0) {
      const unknown: RegionInfo = { tier: RegionTier.UNKNOWN, label: '', code: '' };
      return unknown;
    }
    const lower: string = name.toLowerCase();
    const upper: string = name.toUpperCase();
    for (let i = 0; i < RULES.length; i++) {
      const rule: RegionRule = RULES[i];
      // 旗帜 emoji 最可靠：直接看原串。
      for (let j = 0; j < rule.flags.length; j++) {
        if (name.indexOf(rule.flags[j]) >= 0) {
          return { tier: rule.tier, label: rule.label, code: rule.code };
        }
      }
      // 关键词：中文不受 toLowerCase 影响，英文统一小写比较。
      for (let j = 0; j < rule.words.length; j++) {
        if (lower.indexOf(rule.words[j]) >= 0) {
          return { tier: rule.tier, label: rule.label, code: rule.code };
        }
      }
      // 国家代码：用大写串 + 独立成词，避免 "RUS" 命中 "US"。
      // 没有代码的规则其正则为空串（会匹配一切），必须先判空。
      if (rule.codePattern.length > 0 && CODE_PATTERNS[i].test(upper)) {
        return { tier: rule.tier, label: rule.label, code: rule.code };
      }
    }
    const unknown: RegionInfo = { tier: RegionTier.UNKNOWN, label: '', code: '' };
    return unknown;
  }

  /** 批量分类，结果按节点名索引。一次遍历，避免后续反复跑正则。 */
  static classifyAll(nodes: ParsedNode[]): Map<string, RegionInfo> {
    const map: Map<string, RegionInfo> = new Map<string, RegionInfo>();
    for (let i = 0; i < nodes.length; i++) {
      map.set(nodes[i].name, ProxyRegion.classify(nodes[i].name));
    }
    return map;
  }

  /**
   * 按地区优先级重排节点（同一优先级内保持原顺序）。
   *
   * 用分桶而不是 sort：既保证稳定，也不依赖运行时排序算法的稳定性；
   * 测速按返回顺序领取节点，排在前面的地区会先被预算覆盖到。
   */
  static order(nodes: ParsedNode[], regions: Map<string, RegionInfo>): ParsedNode[] {
    const buckets: ParsedNode[][] = [[], [], [], [], [], []];
    for (let i = 0; i < nodes.length; i++) {
      const node: ParsedNode = nodes[i];
      const info: RegionInfo | undefined = regions.get(node.name);
      const tier: number = info !== undefined ? info.tier : RegionTier.UNKNOWN;
      const index: number = tier >= 0 && tier < buckets.length ? tier : RegionTier.UNKNOWN;
      buckets[index].push(node);
    }
    const out: ParsedNode[] = [];
    for (let i = 0; i < buckets.length; i++) {
      for (let j = 0; j < buckets[i].length; j++) {
        out.push(buckets[i][j]);
      }
    }
    return out;
  }

  /**
   * 按国家归并节点，用于"每个国家一个负载均衡组"。
   *
   * 与 order() 的区别：order() 只按 6 个优先级分桶（所有"其它可用地区"挤在同一个桶里），
   * 这里要的是**每个国家各自成组** —— 用户要的是能在「日本」「新加坡」「美国」……
   * 之间挑一个做均衡，而不是把几十个不同国家的节点混在一个池子里。
   *
   * 过滤规则：
   *   · BLOCKED（香港/大陆/俄罗斯…）整组不出现，免得用户误选到 ChatGPT 打不开的出口；
   *   · 识别不出国家的节点归入「未知地区」一组 —— 无法保证同国，所以这组只在
   *     用户主动选它时才会用到，不会自动参与选路。
   * 排序：先按优先级（日本 → 新加坡 → 美国 → 其它），同级按节点数从多到少，
   * 最后按名字，保证每次生成顺序稳定（配置内容不变，内核不会因为抖动反复重载）。
   */
  static pools(nodes: ParsedNode[], regions: Map<string, RegionInfo>): CountryPool[] {
    const byLabel: Map<string, CountryPool> = new Map<string, CountryPool>();
    for (let i = 0; i < nodes.length; i++) {
      const node: ParsedNode = nodes[i];
      const info: RegionInfo | undefined = regions.get(node.name);
      const tier: number = info !== undefined ? info.tier : RegionTier.UNKNOWN;
      if (tier === RegionTier.BLOCKED) {
        continue;
      }
      const label: string = ProxyRegion.label(info);
      const code: string = info !== undefined ? info.code : '';
      const existing: CountryPool | undefined = byLabel.get(label);
      if (existing !== undefined) {
        existing.nodes.push(node.name);
      } else {
        const pool: CountryPool = { label: label, code: code, nodes: [node.name], tier: tier };
        byLabel.set(label, pool);
      }
    }
    const out: CountryPool[] = [];
    byLabel.forEach((pool: CountryPool) => { out.push(pool); });
    out.sort((a: CountryPool, b: CountryPool): number => {
      if (a.tier !== b.tier) { return a.tier - b.tier; }
      if (a.nodes.length !== b.nodes.length) { return b.nodes.length - a.nodes.length; }
      return a.label < b.label ? -1 : (a.label > b.label ? 1 : 0);
    });
    return out;
  }

  /** 该地区是否明确不可用。 */
  static isBlocked(info: RegionInfo | undefined): boolean {
    return info !== undefined && info.tier === RegionTier.BLOCKED;
  }

  /** 展示用地区名：识别不出时给"未知地区"。 */
  static label(info: RegionInfo | undefined): string {
    if (info === undefined || info.label.length === 0) {
      return '未知地区';
    }
    return info.label;
  }

  /**
   * 策略组名里用的地区名：中英并列，例如「JP 日本」「SG 新加坡」。
   *
   * 用户要求名字里同时有国家代码和中文，这样在长长的策略组列表里，
   * 既能按熟悉的两位代码一眼定位（JP/SG/US），也不会丢掉中文可读性。
   * 识别不出代码时退回纯中文，不显示空括号。
   */
  static displayName(label: string, code: string): string {
    if (code.length === 0) {
      return label;
    }
    return code + ' ' + label;
  }
}
