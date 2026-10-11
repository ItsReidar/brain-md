# Finder Integration

Brain.md opens Markdown files from Finder and the terminal, and previews them in Quick Look.

## Opening Markdown files

Brain.md registers for the Markdown type (`net.daringfireball.markdown`: `.md`, `.markdown`, `.mdown`, `.mkd`, `.mkdn`), so it appears in Finder's **Open With** menu. Double-click, Open With and dropping a file on the Dock icon all go through the app delegate (`AppDelegate` in `Services/ExternalFiles.swift`).

- **A file inside the vault** opens as that note, exactly as if you'd picked it in the sidebar.
- **A file anywhere else** opens in the same editor and preview. A bar above the editor says it's outside your vault and where it is, with **Show in Finder** and **Add to Vault**.
  - **Save (⌘S)** and auto-save write back to the file itself; the vault isn't touched.
  - **Add to Vault** copies the file, including unsaved edits, into the vault root (with a unique name if one exists) and opens the copy. The original keeps its last saved contents.
  - Switching to a vault note saves the outside file first, like any note.
  - Relative images next to the file show in the preview. Outside files aren't watched for changes by other apps, and wikilinks resolve only within the vault.

### Making Brain.md the default

**Settings › General › Markdown Files** shows which app Finder currently opens Markdown files with, and **Make Brain.md the Default** changes it (macOS asks you to confirm). Brain.md registers with the `Default` handler rank, so it never takes over without that confirmation when you've already chosen another app. You can also use Finder's **Get Info › Open with › Change All**.

### From the terminal

The `brain` command opens files in Brain.md, the same way Finder does:

```bash
brain notes.md ~/Desktop/todo.md
```

`brain` on its own just opens the app. Homebrew installs the command with the app. Without Homebrew, link it yourself:

```bash
ln -s /Applications/brain-md.app/Contents/Resources/brain /usr/local/bin/brain
```

The command is a short shell script (`brain-md/Resources/brain`) that runs `open -b itsreidar.brain-md`, so it reaches the installed app through Launch Services. Files must already exist.

## Quick Look preview

Pressing Space on a Markdown file in Finder shows it rendered like Brain.md's preview: headings, emphasis, lists and task lists, tables, callouts, highlighted code blocks, front matter and images next to the file. The preview follows the system's light or dark appearance (GitHub Light and GitHub Dark).

Previews are static and private:

- **No scripts:** Mermaid diagrams show as highlighted code, and code blocks have no copy button.
- **No network:** a content security policy blocks every load. Remote images show their alt text (🖼 Chart) rather than contacting the server, so previewing a file never reveals that you opened it. Local images that can't be read show their alt text too.
- **Sandboxed:** the extension (`brain-md-QuickLook`) only reads the file being previewed and the images it references.

If another app's Quick Look extension also handles Markdown (MarkEdit, QLMarkdown and others do), macOS uses one of them. Choose in **System Settings › General › Login Items & Extensions › Quick Look**.

## Code map

| File | Role |
|---|---|
| `Config/brain-md-Info.plist` | Document type and Markdown type declaration, merged into the generated Info.plist |
| `brain-md/Services/ExternalFiles.swift` | Opening files from Finder, outside-the-vault notes, Add to Vault, default-app helpers, app delegate |
| `brain-md/Resources/brain` | The `brain` terminal command, linked by the Homebrew cask's `binary` stanza |
| `brain-md/Services/MarkdownQuickLook.swift` | Static Quick Look HTML: light and dark styles, Mermaid as code, image attachments and placeholders |
| `brain-md-QuickLook/PreviewProvider.swift` | The Quick Look preview extension (data-based HTML preview) |

The extension compiles the renderer's sources from the app folder through the synchronized folder's membership exceptions (`project.pbxproj`, "Exceptions for "brain-md" folder in "brain-md-QuickLook" target"). A new file the renderer depends on has to be added to that list.

## Testing

`ExternalFilesTests` and `MarkdownQuickLookTests` cover opening, saving and adding outside files, and the preview HTML. To try the extension by hand, build and run the app once (that registers it), then:

```bash
qlmanage -r && qlmanage -p path/to/note.md
```

The extension logs each render to the unified log, which shows whether macOS picked it and how many images it could attach:

```bash
/usr/bin/log show --last 5m --info --predicate 'subsystem == "itsreidar.brain-md.QuickLook"'
```

Use `/usr/bin/log`; zsh has a `log` builtin that shadows it. A development build registers its extension and document types with macOS; to stop it from handling your files afterwards, unregister it:

```bash
pluginkit -r path/to/brain-md.app/Contents/PlugIns/brain-md-QuickLook.appex
```
