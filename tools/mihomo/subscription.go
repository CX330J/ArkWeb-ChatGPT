package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"reflect"
	"sort"
	"time"
	"unicode"

	"github.com/dlclark/regexp2"
	"strings"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/common/convert"
	"go.yaml.in/yaml/v3"
)

type providerPayload struct {
	Name string `json:"name"`
	Body string `json:"body"`
}
type normalizeInput struct {
	Body      string            `json:"body"`
	Providers []providerPayload `json:"providers"`
}
type providerRequest struct {
	Name string `json:"name"`
	URL  string `json:"url"`
}
type normalizeResult struct {
	OK        bool              `json:"ok"`
	YAML      string            `json:"yaml"`
	Error     string            `json:"error,omitempty"`
	Providers []providerRequest `json:"providers"`
}

func normalizedSubscription(input normalizeInput) (result normalizeResult) {
	result.Providers = []providerRequest{}
	defer func() {
		if recover() != nil {
			result.OK = false
			result.Error = "订阅包含无效字段"
		}
	}()
	body := strings.TrimSpace(strings.TrimPrefix(input.Body, "\ufeff"))
	decoded := decodeSubscription(body)
	var document map[string]any
	if err := yaml.Unmarshal(decoded, &document); err != nil || document == nil {
		proxies, convertErr := convert.ConvertsV2Ray(decoded)
		// 原生转换器会忽略坏行；逐行转换可确保不会静默丢节点。
		if convertErr != nil {
			result.Error = "无法识别订阅，请检查链接或订阅格式"
			return
		}
		expected := 0
		for _, line := range strings.Split(string(decoded), "\n") {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			if _, err := convert.ConvertsV2Ray([]byte(line)); err != nil {
				result.Error = fmt.Sprintf("第 %d 条节点链接无法识别", expected+1)
				return
			}
			expected++
		}
		if len(proxies) != expected {
			result.Error = "订阅包含无法转换的节点"
			return
		}
		document = map[string]any{"proxies": proxies}
	}
	nodes, err := proxyMaps(document["proxies"])
	if err != nil {
		result.Error = err.Error()
		return
	}
	names := map[string]bool{}
	for _, node := range nodes {
		name, _ := node["name"].(string)
		if name == "" || names[name] {
			result.Error = "节点名称为空或重复：" + name
			return
		}
		names[name] = true
	}
	byProvider := map[string][]map[string]any{}
	providerURLs := map[string]string{}
	providerNames := []string{}
	if providers, ok := document["proxy-providers"].(map[string]any); ok {
		for name := range providers {
			providerNames = append(providerNames, name)
		}
		sort.Strings(providerNames)
		for _, name := range providerNames {
			raw := providers[name]
			provider, ok := raw.(map[string]any)
			if !ok {
				result.Error = "无效的节点提供者：" + name
				return
			}
			if health, ok := provider["health-check"].(map[string]any); ok {
				providerURLs[name], _ = health["url"].(string)
			}
			var entries []map[string]any
			if payload, ok := provider["payload"]; ok {
				entries, err = proxyMaps(payload)
			}
			for _, supplied := range input.Providers {
				if supplied.Name != name {
					continue
				}
				var parsed map[string]any
				if err = yaml.Unmarshal(decodeSubscription(supplied.Body), &parsed); err == nil && parsed != nil {
					entries, err = proxyMaps(parsed["proxies"])
				} else {
					entries, err = convert.ConvertsV2Ray(decodeSubscription(supplied.Body))
				}
			}
			if err != nil {
				result.Error = "节点提供者解析失败：" + name
				return
			}
			if len(entries) == 0 {
				url, _ := provider["url"].(string)
				if !strings.HasPrefix(url, "https://") && !strings.HasPrefix(url, "http://") {
					result.Error = "节点提供者缺少可下载的地址：" + name
					return
				}
				result.Providers = append(result.Providers, providerRequest{Name: name, URL: url})
				continue
			}
			entries, err = prepareProvider(entries, provider)
			if err != nil {
				result.Error = "节点提供者配置无效：" + name + "（" + err.Error() + "）"
				return
			}
			for _, node := range entries {
				nodeName, _ := node["name"].(string)
				if nodeName == "" {
					result.Error = "节点提供者包含空名称：" + name
					return
				}
				if names[nodeName] {
					for _, existing := range nodes {
						if existing["name"] == nodeName && !reflect.DeepEqual(existing, node) {
							result.Error = "不同节点使用了同一名称：" + nodeName
							return
						}
					}
				} else {
					nodes = append(nodes, node)
					names[nodeName] = true
				}
			}
			byProvider[name] = entries
		}
	}
	if len(result.Providers) > 0 {
		result.OK = true
		return
	}
	if len(nodes) == 0 {
		result.Error = "订阅没有可用节点"
		return
	}
	for _, node := range nodes {
		if _, err := adapter.ParseProxy(node); err != nil {
			result.Error = "节点配置无效：" + fmt.Sprint(node["name"]) + "（" + err.Error() + "）"
			return
		}
	}
	groups, err := proxyMaps(document["proxy-groups"])
	if err != nil {
		result.Error = err.Error()
		return
	}
	allNames := map[string]bool{"DIRECT": true, "REJECT": true, "REJECT-DROP": true, "PASS": true, "COMPATIBLE": true}
	for name := range names {
		allNames[name] = true
	}
	for _, group := range groups {
		name, _ := group["name"].(string)
		if name == "" || allNames[name] {
			result.Error = "策略名称为空或重复：" + name
			return
		}
		allNames[name] = true
	}
	for _, group := range groups {
		members := stringList(group["proxies"])
		uses := stringList(group["use"])
		if group["include-all"] == true || group["include-all-providers"] == true {
			uses = providerNames
		}
		for _, use := range uses {
			if group["url"] == nil && providerURLs[use] != "" {
				group["url"] = providerURLs[use]
			}
			entries, exists := byProvider[use]
			if !exists {
				result.Error = "找不到节点提供者：" + use
				return
			}
			for _, entry := range entries {
				members = appendUnique(members, fmt.Sprint(entry["name"]))
			}
		}
		if group["include-all"] == true || group["include-all-proxies"] == true {
			for _, node := range nodes {
				members = appendUnique(members, fmt.Sprint(node["name"]))
			}
		}
		filter, _ := group["filter"].(string)
		exclude, _ := group["exclude-filter"].(string)
		includeRE, err := subscriptionFilters(filter)
		if err != nil {
			result.Error = "无效的分组筛选表达式"
			return
		}
		excludeRE, err := subscriptionFilters(exclude)
		if err != nil {
			result.Error = "无效的分组排除表达式"
			return
		}
		filtered := []string{}
		for _, member := range members {
			if len(includeRE) > 0 && !matchesFilter(includeRE, member) || matchesFilter(excludeRE, member) {
				continue
			}
			if !allNames[member] {
				result.Error = "分组引用了不存在的节点：" + member
				return
			}
			filtered = appendUnique(filtered, member)
		}
		if len(filtered) == 0 {
			result.Error = "策略组没有可用成员：" + fmt.Sprint(group["name"])
			return
		}
		group["proxies"] = filtered
		delete(group, "use")
		delete(group, "include-all")
		delete(group, "include-all-proxies")
		delete(group, "include-all-providers")
		delete(group, "filter")
		delete(group, "exclude-filter")
	}
	if err := validateGroupCycles(groups); err != nil {
		result.Error = err.Error()
		return
	}
	document["proxies"] = nodes
	document["proxy-groups"] = groups
	delete(document, "proxy-providers")
	// 只输出运行时会消费的段，避免未引用的锚点模板混入配置。
	output := map[string]any{"proxies": nodes, "proxy-groups": groups}
	for _, key := range []string{"rules", "rule-providers"} {
		if value, ok := document[key]; ok {
			output[key] = value
		}
	}
	var buffer bytes.Buffer
	encoder := yaml.NewEncoder(&buffer)
	encoder.SetIndent(2)
	if err = encoder.Encode(output); err != nil {
		result.Error = "订阅 YAML 转换失败"
		return
	}
	result.OK = true
	result.YAML = buffer.String()
	return
}

func proxyMaps(value any) ([]map[string]any, error) {
	if value == nil {
		return nil, nil
	}
	encoded, err := yaml.Marshal(value)
	if err != nil {
		return nil, err
	}
	var result []map[string]any
	if err = yaml.Unmarshal(encoded, &result); err != nil {
		return nil, fmt.Errorf("节点或策略列表格式无效")
	}
	return result, nil
}
func stringList(value any) []string {
	var result []string
	encoded, _ := yaml.Marshal(value)
	_ = yaml.Unmarshal(encoded, &result)
	return result
}
func appendUnique(values []string, value string) []string {
	for _, existing := range values {
		if existing == value {
			return values
		}
	}
	return append(values, value)
}
func normalizeJSON(inputText string) string {
	var input normalizeInput
	if err := json.Unmarshal([]byte(inputText), &input); err != nil {
		return `{"ok":false,"error":"订阅输入无效","providers":[]}`
	}
	result := normalizedSubscription(input)
	encoded, _ := json.Marshal(result)
	return string(encoded)
}

// 只尝试解码整个订阅；普通 YAML/URI 原文保持不变。
func decodeSubscription(body string) []byte {
	body = strings.TrimSpace(strings.TrimPrefix(body, "\ufeff"))
	compact := strings.Map(func(r rune) rune {
		if unicode.IsSpace(r) {
			return -1
		}
		return r
	}, body)
	if decoded, err := convert.TryDecodeBase64(compact); err == nil {
		return decoded
	}
	return []byte(body)
}
func subscriptionFilters(expression string) ([]*regexp2.Regexp, error) {
	var filters []*regexp2.Regexp
	if expression == "" {
		return filters, nil
	}
	for _, part := range strings.Split(expression, "`") {
		compiled, err := regexp2.Compile(part, regexp2.None)
		if err != nil {
			return nil, err
		}
		compiled.MatchTimeout = 100 * time.Millisecond
		filters = append(filters, compiled)
	}
	return filters, nil
}
func matchesFilter(filters []*regexp2.Regexp, name string) bool {
	for _, filter := range filters {
		if matched, err := filter.MatchString(name); err == nil && matched {
			return true
		}
	}
	return false
}
func prepareProvider(entries []map[string]any, settings map[string]any) ([]map[string]any, error) {
	include, _ := settings["filter"].(string)
	exclude, _ := settings["exclude-filter"].(string)
	includeRE, err := subscriptionFilters(include)
	if err != nil {
		return nil, err
	}
	excludeRE, err := subscriptionFilters(exclude)
	if err != nil {
		return nil, err
	}
	overrides, _ := settings["override"].(map[string]any)
	result := []map[string]any{}
	for _, entry := range entries {
		name, _ := entry["name"].(string)
		if len(includeRE) > 0 && !matchesFilter(includeRE, name) || matchesFilter(excludeRE, name) {
			continue
		}
		for key, value := range overrides {
			switch key {
			case "additional-prefix", "additional-suffix", "proxy-name":
			case "override-expr":
				return nil, fmt.Errorf("暂不支持 override-expr")
			default:
				entry[key] = value
			}
		}
		if replacements, ok := overrides["proxy-name"]; ok {
			rules, err := proxyMaps(replacements)
			if err != nil {
				return nil, err
			}
			for _, rule := range rules {
				pattern, _ := rule["pattern"].(string)
				target, _ := rule["target"].(string)
				regex, err := regexp2.Compile(pattern, regexp2.None)
				if err != nil {
					return nil, err
				}
				regex.MatchTimeout = 100 * time.Millisecond
				name, err = regex.Replace(name, target, 0, -1)
				if err != nil {
					return nil, err
				}
			}
		}
		prefix, _ := overrides["additional-prefix"].(string)
		suffix, _ := overrides["additional-suffix"].(string)
		entry["name"] = prefix + name + suffix
		result = append(result, entry)
	}
	return result, nil
}
func validateGroupCycles(groups []map[string]any) error {
	members := map[string][]string{}
	state := map[string]int{}
	for _, group := range groups {
		name, _ := group["name"].(string)
		members[name] = stringList(group["proxies"])
	}
	var visit func(string) error
	visit = func(name string) error {
		if state[name] == 1 {
			return fmt.Errorf("策略分组循环引用：%s", name)
		}
		if state[name] == 2 {
			return nil
		}
		children, ok := members[name]
		if !ok {
			return nil
		}
		state[name] = 1
		for _, child := range children {
			if err := visit(child); err != nil {
				return err
			}
		}
		state[name] = 2
		return nil
	}
	for name := range members {
		if err := visit(name); err != nil {
			return err
		}
	}
	return nil
}
