import { describe, expect, test } from 'claude-code/testing'

import { linkify, mergeRepos, parseGitHubRemote, repoIndex } from '../hooks/linkify'
import type { LinkContext } from '../hooks/linkify'

const CURRENT = 'maguerrieri/claude-toolbox'
const KNOWN = ['maguerrieri/www', 'maguerrieri/provenance', 'maguerrieri/claude-toolbox']
const ctx = { current: CURRENT, known: KNOWN }
const link = (text: string, context: LinkContext) => linkify(text, repoIndex(context))

const issue = (repo: string, n: number) => `https://github.com/${repo}/issues/${n}`

describe('resolution rules', () => {
  test('owner/repo#N links to that repo, known or not', () => {
    expect(link('see maguerrieri/provenance#3', ctx)).toBe(
      `see [maguerrieri/provenance#3](${issue('maguerrieri/provenance', 3)})`,
    )
    expect(link('see octo/widgets#12.', { current: null, known: [] })).toBe(
      `see [octo/widgets#12](${issue('octo/widgets', 12)}).`,
    )
  })

  test('owner/repo #N with one space links when the repo is known', () => {
    expect(link('maguerrieri/www #12 landed', ctx)).toBe(
      `[maguerrieri/www #12](${issue('maguerrieri/www', 12)}) landed`,
    )
  })

  test('an unknown a/b word with one space leaves the #N unlinked', () => {
    for (const text of ['pushed to origin/main #219', 'and/or #12', 'edited hooks/register.tsx #224', 'octo/widgets #12']) {
      expect(link(text, ctx), text).toBe(text)
    }
  })

  test('a wrapped repo name still names the repo, and the link covers the #N', () => {
    const www = (n: number) => issue('maguerrieri/www', n)
    expect(link('**www** #8', ctx)).toBe(`**www** [#8](${www(8)})`)
    expect(link('`www` #8', ctx)).toBe(`\`www\` [#8](${www(8)})`)
    expect(link('_www_ #8', ctx)).toBe(`_www_ [#8](${www(8)})`)
    expect(link('(www) #8', ctx)).toBe(`(www) [#8](${www(8)})`)
    expect(link('**PR** #9', ctx)).toBe(`**PR** [#9](${issue(CURRENT, 9)})`)
  })

  test('a repo name with an underscore', () => {
    expect(link('my_repo #3', { current: null, known: ['octo/my_repo'] })).toBe(
      `[my_repo #3](${issue('octo/my_repo', 3)})`,
    )
  })

  test('a known repo name before #N links to that repo, either spacing', () => {
    expect(link('www #8 and www#9', ctx)).toBe(
      `[www #8](${issue('maguerrieri/www', 8)}) and [www#9](${issue('maguerrieri/www', 9)})`,
    )
  })

  test('the repo name matches case-insensitively and keeps its spelling', () => {
    expect(link('WWW #8', ctx)).toBe(`[WWW #8](${issue('maguerrieri/www', 8)})`)
  })

  test('a session-name prefix resolves through the name', () => {
    expect(link('claude-toolbox #217: fix', ctx)).toBe(
      `[claude-toolbox #217](${issue(CURRENT, 217)}): fix`,
    )
  })

  test('a bare #N links to the current repo', () => {
    expect(link('#219', ctx)).toBe(`[#219](${issue(CURRENT, 219)})`)
    expect(link('Merged (#42).', ctx)).toBe(`Merged ([#42](${issue(CURRENT, 42)})).`)
  })

  test('#N after a word that is no known repo links to the current repo', () => {
    expect(link('PR #219, issue #218 and #42', ctx)).toBe(
      `PR [#219](${issue(CURRENT, 219)}), issue [#218](${issue(CURRENT, 218)}) and [#42](${issue(CURRENT, 42)})`,
    )
  })

  test('the three forms in one reply', () => {
    expect(link('#219, www #8 and maguerrieri/provenance#3', ctx)).toBe(
      `[#219](${issue(CURRENT, 219)}), [www #8](${issue('maguerrieri/www', 8)}) and ` +
        `[maguerrieri/provenance#3](${issue('maguerrieri/provenance', 3)})`,
    )
  })

  test('a bare #N stays unlinked without a current repo', () => {
    expect(link('PR #219', { current: null, known: KNOWN })).toBe('PR #219')
  })

  test('the current repo counts as known even when the list lacks it', () => {
    expect(link('claude-toolbox #5', { current: CURRENT, known: [] })).toBe(
      `[claude-toolbox #5](${issue(CURRENT, 5)})`,
    )
  })
})

describe('ambiguous names', () => {
  const twoOwners = ['alice/www', 'bob/www']

  test('a name under two owners prefers the current repo owner', () => {
    expect(link('www #8', { current: 'bob/site', known: twoOwners })).toBe(
      `[www #8](${issue('bob/www', 8)})`,
    )
  })

  test('a name under two owners, neither the current one, stays unlinked', () => {
    expect(link('www #8', { current: 'carol/site', known: twoOwners })).toBe('www #8')
    expect(link('www#8', { current: null, known: twoOwners })).toBe('www#8')
  })

  test('the same repo listed twice in different case is not ambiguous', () => {
    expect(link('www #8', { current: null, known: ['alice/www', 'Alice/WWW'] })).toBe(
      `[www #8](${issue('alice/www', 8)})`,
    )
  })
})

describe("don't touch", () => {
  const same = (text: string) => expect(link(text, ctx)).toBe(text)

  test('code spans', () => {
    same('run `gh pr view #219` now')
    same('``a ` #12``')
  })

  test('fenced code blocks', () => {
    same('```\n#219\nwww #8\n```')
    same('~~~md\n#1\n~~~')
    same('1. step\n   ```bash\n   echo #12\n   ```')
  })

  test('indented code blocks', () => {
    same('    echo #12')
    expect(link('para #1\n\n    echo #12\n\n    more #13\nafter #3', ctx)).toBe(
      `para [#1](${issue(CURRENT, 1)})\n\n    echo #12\n\n    more #13\nafter [#3](${issue(CURRENT, 3)})`,
    )
  })

  test('a fence four columns in, after a blank line, is indented code, not a fence', () => {
    expect(link('para\n\n    ```\n    x #1\n\nsee #12', ctx)).toBe(
      `para\n\n    \`\`\`\n    x #1\n\nsee [#12](${issue(CURRENT, 12)})`,
    )
  })

  test('a nested list item four columns in is still prose', () => {
    expect(link('- a\n\n    - b #4', ctx)).toBe(`- a\n\n    - b [#4](${issue(CURRENT, 4)})`)
  })

  test('a paragraph line indented four columns continues the paragraph', () => {
    expect(link('para\n    more #5', ctx)).toBe(`para\n    more [#5](${issue(CURRENT, 5)})`)
  })

  test('link reference definitions and the shortcut links they define', () => {
    same('See [#12].\n\n[#12]: https://example.com/x')
    same('[docs #3]: <https://example.com>')
  })

  test('an unclosed fence runs to the end', () => {
    same('```\n#219')
  })

  test('text after a fence is still linked', () => {
    expect(link('```\n#1\n```\nsee #2', ctx)).toBe(`\`\`\`\n#1\n\`\`\`\nsee [#2](${issue(CURRENT, 2)})`)
  })

  test('existing links, autolinks and bare URLs', () => {
    same('[PR #219](https://github.com/o/r/pull/219)')
    same('![shot #2](img.png)')
    same('[see #4][ref]')
    same('<https://example.com/#12>')
    same('https://example.com/a/#12 and www.example.com/#3')
  })

  test('headings', () => {
    same('### Title')
    same('## Fixes #12')
  })

  test('a # inside a word', () => {
    same('C# and F#')
    same('foo#12 and a-#3 and x/#4')
    same('&#123; entity')
  })

  test('#N past seven digits, #0 and leading zeros', () => {
    same('#12345678')
    same('#0 and #007')
  })

  test('hex colours with letters', () => {
    same('#3a3 and #fff and #12ab')
  })

  test('an escaped #', () => {
    same('\\#12')
  })

  test('a token ending in a period is a sentence, not a repo', () => {
    expect(link('see octo/widgets. #12', ctx)).toBe(`see octo/widgets. [#12](${issue(CURRENT, 12)})`)
  })
})

describe('pass-through', () => {
  test('a reply with no references comes back unchanged', () => {
    const text = 'Nothing to link here.\n\n- a list\n- `code`'
    expect(link(text, ctx)).toBe(text)
  })

  test('an empty cache links only the owner/repo forms and the current repo', () => {
    const empty = { current: CURRENT, known: [] }
    expect(link('www #8, #9 and octo/widgets#1', empty)).toBe(
      `www [#8](${issue(CURRENT, 8)}), [#9](${issue(CURRENT, 9)}) and [octo/widgets#1](${issue('octo/widgets', 1)})`,
    )
  })
})

describe('parseGitHubRemote', () => {
  test('reads the GitHub remote spellings', () => {
    for (const url of [
      'git@github.com:maguerrieri/claude-toolbox.git',
      'git@github.com:maguerrieri/claude-toolbox',
      'https://github.com/maguerrieri/claude-toolbox.git',
      'https://github.com/maguerrieri/claude-toolbox/',
      'https://token@github.com/maguerrieri/claude-toolbox',
      'ssh://git@github.com/maguerrieri/claude-toolbox.git',
      'ssh://git@ssh.github.com:443/maguerrieri/claude-toolbox.git',
      'git://github.com/maguerrieri/claude-toolbox.git',
    ]) {
      expect(parseGitHubRemote(url), url).toBe('maguerrieri/claude-toolbox')
    }
  })

  test('keeps dots in repo names', () => {
    expect(parseGitHubRemote('git@github.com:octo/octo.github.io.git')).toBe('octo/octo.github.io')
  })

  test('rejects other hosts and aliases', () => {
    for (const url of [
      'git@gitlab.com:o/r.git',
      'https://github.example.com/o/r.git',
      'github-work:o/r.git',
      'https://notgithub.com/o/r',
      '/local/path/repo',
    ]) {
      expect(parseGitHubRemote(url), url).toBeNull()
    }
  })
})

describe('mergeRepos', () => {
  test('dedupes case-insensitively, keeps the first spelling, sorts, drops junk', () => {
    expect(mergeRepos(['b/x', 'A/y', 'a/Y', 'not a repo', '', 'b/x'])).toEqual(['A/y', 'b/x'])
  })
})
