import AppKit
import JavaScriptCore
import WebKit
import XCTest
@testable import Washi

/// 生成された JS の style 要素の出自判定。著者の同名 id を書き換えず、自前の要素を
/// 一つだけ保つことを簡易 DOM 上で検証する(WebKit の描画は不要)。
@MainActor
final class ReaderScriptStyleOwnershipTests: XCTestCase {
    /// 生成された JS を簡易 DOM 上で実行し、著者の同名 id を書き換えずに
    /// 内部 style を作成・再利用することを検証する。WebKit の描画は不要。
    func testGeneratedStyleScriptPreservesAuthorIDCollisions() throws {
        for (tag, marked, hasDataset) in [
            ("div", false, true), ("style", false, true),
            ("div", true, true), ("style", false, false),
        ] {
            let context = try makeStyleScriptContext()
            let result = context.evaluateScript("""
                const ids = ['washi-base', 'washi-pagination', 'washi-user',
                             'washi-font-scale', 'washi-default-font'];
                const authors = ids.map(id => {
                    const author = document.createElement('\(tag)');
                    author.id = id;
                    author.textContent = '著者の内容';
                    if (\(marked)) { author.dataset.washiOwned = '1'; }
                    if (!\(hasDataset)) { delete author.dataset; }
                    document.head.appendChild(author);
                    return author;
                });
                const preserved = authors.every(author => {
                    const owned = __washi.styleTest.ensureStyle(author.id);
                    owned.textContent = 'html { color: red; }';
                    return owned !== author && owned.localName === 'style'
                        && owned.dataset.washiOwned === '1'
                        && owned.id === author.id
                        && __washi.styleTest.ensureStyle(author.id) === owned
                        && author.textContent === '著者の内容'
                        && author.parentNode === document.head;
                });
                __washi.styleTest.installDefaultFontCSS('html { font-family: serif; }');
                __washi.styleTest.installDefaultFontCSS('html { font-family: sans-serif; }');
                const font = __washi.styleTest.findOwnedStyle('washi-default-font');
                preserved && authors.every(author => author.textContent === '著者の内容')
                    && font.textContent === 'html { font-family: sans-serif; }'
                    && document.querySelectorAll('style[data-washi-owned="1"]').length === ids.length;
                """)
            XCTAssertNil(context.exception, "\(tag), \(marked): \(String(describing: context.exception))")
            XCTAssertTrue(try XCTUnwrap(result).toBool(), "\(tag), \(marked)")
        }
    }

    /// 基礎 CSS の起動スクリプトも同じ出自判定を行い、著者要素を移動しない。
    /// 再注入しても自前の要素は一つだけに保つ。
    func testGeneratedBaseCSSInjectorPreservesAuthorIDCollisions() throws {
        for (tag, marked, hasDataset) in [
            ("div", false, true), ("style", false, true),
            ("div", true, true), ("style", false, false),
        ] {
            let context = try makeStyleScriptContext()
            context.evaluateScript("""
                const author = document.createElement('\(tag)');
                author.id = 'washi-base';
                author.textContent = '著者の内容';
                if (\(marked)) { author.dataset.washiOwned = '1'; }
                if (!\(hasDataset)) { delete author.dataset; }
                document.body.appendChild(author);
                """)
            context.evaluateScript(ReaderScripts.baseCSSInjector)
            XCTAssertNil(context.exception)
            context.evaluateScript(ReaderScripts.baseCSSInjector)
            let result = context.evaluateScript("""
                const owned = document.head.firstChild;
                owned !== author && owned.localName === 'style'
                    && owned.id === 'washi-base' && owned.dataset.washiOwned === '1'
                    && owned.textContent.includes('@font-face')
                    && author.textContent === '著者の内容'
                    && author.parentNode === document.body
                    && document.head.children.length === 1;
                """)
            XCTAssertNil(context.exception, "\(tag), \(marked): \(String(describing: context.exception))")
            XCTAssertTrue(try XCTUnwrap(result).toBool(), "\(tag), \(marked)")
        }
    }

    private func makeStyleScriptContext() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        // 必要な DOM 操作だけを実装する。イベント登録は受け付けるが発火しない。
        context.evaluateScript(#"""
            class Element {
                constructor(name) {
                    this.localName = name;
                    this.namespaceURI = 'http://www.w3.org/1999/xhtml';
                    this.id = '';
                    this.dataset = {};
                    this.textContent = '';
                    this.parentNode = null;
                    this.children = [];
                }
                get firstChild() { return this.children[0] || null; }
                get nextSibling() {
                    if (!this.parentNode) { return null; }
                    const siblings = this.parentNode.children;
                    return siblings[siblings.indexOf(this) + 1] || null;
                }
                appendChild(el) { return this.insertBefore(el, null); }
                insertBefore(el, next) {
                    if (el === next) { return el; }
                    if (el.parentNode) {
                        const previous = el.parentNode.children;
                        previous.splice(previous.indexOf(el), 1);
                    }
                    const index = next ? this.children.indexOf(next) : this.children.length;
                    this.children.splice(index, 0, el);
                    el.parentNode = this;
                    return el;
                }
                getAttribute(name) {
                    return name === 'data-washi-owned' ? this.dataset?.washiOwned || null : null;
                }
                setAttribute(name, value) {
                    if (name === 'data-washi-owned') { this.dataset.washiOwned = value; }
                }
            }
            var window = this;
            window.addEventListener = function () {};
            window.setTimeout = function () { return 1; };
            window.clearTimeout = function () {};
            var document = {
                head: new Element('head'), body: new Element('body'),
                createElement: name => new Element(name),
                createElementNS(namespace, name) {
                    const el = new Element(name);
                    el.namespaceURI = namespace;
                    return el;
                },
                addEventListener() {}, removeEventListener() {},
                getElementById(id) {
                    return [...this.head.children, ...this.body.children]
                        .find(el => el.id === id) || null;
                },
                querySelectorAll(selector) {
                    if (selector !== 'style[data-washi-owned="1"]') {
                        throw new Error('未対応の selector: ' + selector);
                    }
                    return [...this.head.children, ...this.body.children].filter(el =>
                        el.localName === 'style' && el.dataset?.washiOwned === '1');
                }
            };
            """#)
        // 生成物をそのまま評価し、非公開関数への入口だけをテスト内で追加する。
        let script = ReaderScripts.pageScript.replacingOccurrences(
            of: "window.__washi = washi;", with: """
                window.__washi = washi;
                washi.styleTest = { ensureStyle, findOwnedStyle, installDefaultFontCSS };
                """)
        context.evaluateScript(script)
        XCTAssertNil(context.exception, String(describing: context.exception))
        return context
    }
}
