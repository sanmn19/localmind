import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/mcp/data/terminal_mcp_server.dart';

void main() {
  group('TerminalWhitelist', () {
    test('empty whitelist allows nothing', () {
      final whitelist = TerminalWhitelist(const []);
      expect(whitelist.allows('ls'), isFalse);
      expect(whitelist.allows('curl -s https://example.com'), isFalse);
      expect(whitelist.allows(''), isFalse);
    });

    test('first-token exact case-sensitive match', () {
      final whitelist = TerminalWhitelist(const ['ls', 'curl']);
      expect(whitelist.allows('ls'), isTrue);
      expect(whitelist.allows('ls -la /tmp'), isTrue);
      expect(whitelist.allows('curl -s https://example.com'), isTrue);
      // Case-sensitive: entries and commands must match letter-for-letter.
      expect(whitelist.allows('LS'), isFalse);
      expect(whitelist.allows('Curl -s https://example.com'), isFalse);
      // Prefix words do not count as matches.
      expect(whitelist.allows('lsof -i'), isFalse);
      expect(whitelist.allows('curls'), isFalse);
    });

    test('entries are trimmed and blank/comment entries are ignored', () {
      final whitelist = TerminalWhitelist(const [
        '',
        '   ',
        '# comment',
        'ping',
        '#even with text',
      ]);
      expect(whitelist.entries, ['ping']);
      expect(whitelist.allows('ping -c 1 host'), isTrue);
      expect(whitelist.allows('# comment'), isFalse);
    });

    test('leading and trailing whitespace of the command is ignored', () {
      final whitelist = TerminalWhitelist(const ['ls']);
      expect(whitelist.allows('  ls  '), isTrue);
    });

    test('unquoted pipe smuggles a tail and is rejected', () {
      final whitelist = TerminalWhitelist(const ['ls']);
      expect(whitelist.allows('ls | rm -rf /'), isFalse);
      expect(whitelist.allows('ls|| rm -rf /'), isFalse);
    });

    test('unquoted semicolons, conditionals and ampersands are rejected', () {
      final whitelist = TerminalWhitelist(const ['ls']);
      expect(whitelist.allows('ls; rm -rf /'), isFalse);
      expect(whitelist.allows('ls && rm -rf /'), isFalse);
      expect(whitelist.allows('ls || rm -rf /'), isFalse);
      expect(whitelist.allows('ls & rm x'), isFalse);
    });

    test('redirections and backticks are rejected even with a match', () {
      final whitelist = TerminalWhitelist(const ['ls', 'cat']);
      expect(whitelist.allows('cat > /sdcard/evil'), isFalse);
      expect(whitelist.allows('cat < /data/secret'), isFalse);
      expect(whitelist.allows('cat `echo evil`'), isFalse);
    });

    test('unquoted command substitution is rejected', () {
      final whitelist = TerminalWhitelist(const ['ls', 'echo']);
      expect(whitelist.allows(r'echo $(rm -rf /)'), isFalse);
      expect(whitelist.allows(r'echo $(cat /data/secret)'), isFalse);
    });

    test('quoted metacharacters are arguments, not shell syntax', () {
      final whitelist = TerminalWhitelist(const ['grep', 'curl']);
      expect(whitelist.allows("grep 'a|b' file"), isTrue);
      expect(whitelist.allows(r'grep "x$(y)" file'), isFalse);
      expect(
        whitelist.allows(r"""curl -s 'https://example.com/?q=a|b'"""),
        isTrue,
      );
    });

    test('quoting edge: pipe after a closing double quote is rejected', () {
      final whitelist = TerminalWhitelist(const ['ls']);
      expect(whitelist.allows('ls "x"| rm'), isFalse);
      expect(whitelist.allows("ls 'x'| rm"), isFalse);
    });

    test('backticks inside double quotes still expand and are rejected', () {
      final whitelist = TerminalWhitelist(const ['echo']);
      expect(whitelist.allows('echo "`id`"'), isFalse);
      expect(whitelist.allows(r'echo "$(id)"'), isFalse);
    });

    test('the net.http entry is a tool-level grant, not a command', () {
      final whitelist = TerminalWhitelist(const ['net.http']);
      expect(whitelist.allowsTool('net.http'), isTrue);
      expect(whitelist.allowsTool('terminal.run'), isFalse);
    });

    test(
      'dollar-sign parameter expansion alone stays allowed outside quotes',
      () {
        // Only `$(`-style substitution and backticks are flagged; a plain
        // `$var` tail is ordinary text. Conservative enough: it may read env
        // vars the app sandbox already exposes, so it goes through only when
        // the first token is whitelisted AND the line has no other metachars.
        final whitelist = TerminalWhitelist(const ['echo']);
        expect(whitelist.allows(r'echo $HOME'), isTrue);
      },
    );
  });
}
