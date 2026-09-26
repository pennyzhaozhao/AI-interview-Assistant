#!/usr/bin/env python3
"""
提词器接收端 v5 - 面试助手版
新增：启动配置窗口（职位、背景文字、PDF上传）
pip install SpeechRecognition sounddevice scipy openai numpy pypdf
"""

import socket
import threading
import tkinter as tk
from tkinter import simpledialog, font as tkfont, filedialog, scrolledtext
import speech_recognition as sr
from openai import OpenAI
import queue
import os
import tempfile
import sqlite3
import json
import urllib.request
import urllib.parse
from datetime import datetime
import numpy as np
import sounddevice as sd
import scipy.io.wavfile as wav
from tkinter import messagebox

PORT = 9999
MODEL = "qwen2.5:7b"
OLLAMA_URL = "http://localhost:11434/v1"
SAMPLE_RATE = 16000
DB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'interview_assistant.sqlite3')
THEME_BG = '#0f1117'
THEME_PANEL = '#161a22'
THEME_FIELD = '#0f1117'
THEME_BORDER = '#262b36'
THEME_TEXT = '#f4f4f5'
THEME_MUTED = '#8b949e'
THEME_BUTTON = '#222733'
THEME_ACCENT = '#f4f4f5'

PROVIDERS = {
    'ollama': {
        'label': 'Ollama 本地',
        'url': OLLAMA_URL,
        'model': MODEL,
        'models': ['qwen2.5:7b', 'llama3.1:8b', 'qwen2.5:14b'],
        'help': '本地 Ollama，默认不需要 API Key。'
    },
    'volcano': {
        'label': '火山方舟 (Volcano Ark)',
        'url': 'https://ark.cn-beijing.volces.com/api/v3',
        'model': 'doubao-seed-1-8-251228',
        'models': ['doubao-seed-1-8-251228', 'doubao-seed-1-6-250615'],
        'help': '火山方舟 API 地址通常填写到 /api/v3，使用 OpenAI 兼容调用。'
    },
    'claude': {
        'label': 'Claude (Anthropic)',
        'url': 'https://api.anthropic.com/v1/messages',
        'model': 'claude-sonnet-4-5',
        'models': ['claude-sonnet-4-5', 'claude-opus-4-1', 'claude-haiku-4-5'],
        'help': 'Claude 使用 Anthropic Messages API。'
    },
    'openai': {
        'label': 'OpenAI / ChatGPT',
        'url': 'https://api.openai.com/v1',
        'model': 'gpt-4.1-mini',
        'models': ['gpt-4.1-mini', 'gpt-4.1', 'gpt-4o-mini', 'gpt-4o'],
        'help': 'OpenAI 官方 API，填写 API Key 后使用。'
    }
}


def now_iso():
    return datetime.now().strftime('%Y-%m-%d %H:%M:%S')


def normalize_api_base(url):
    url = (url or '').strip().rstrip('/')
    for suffix in ('/chat/completions', '/responses', '/messages'):
        if url.endswith(suffix):
            return url[:-len(suffix)]
    return url


def extract_pdf_text(path):
    from pypdf import PdfReader
    reader = PdfReader(path)
    return '\n'.join(page.extract_text() or '' for page in reader.pages)


def google_drive_download_url(url):
    parsed = urllib.parse.urlparse(url)
    if 'drive.google.com' not in parsed.netloc:
        return url
    parts = parsed.path.split('/')
    file_id = ''
    if 'd' in parts:
        idx = parts.index('d')
        if idx + 1 < len(parts):
            file_id = parts[idx + 1]
    if not file_id:
        qs = urllib.parse.parse_qs(parsed.query)
        file_id = (qs.get('id') or [''])[0]
    if file_id:
        return f'https://drive.google.com/uc?export=download&id={file_id}'
    return url


def github_raw_url(url):
    parsed = urllib.parse.urlparse(url)
    if parsed.netloc != 'github.com':
        return url
    parts = parsed.path.strip('/').split('/')
    if len(parts) >= 5 and parts[2] == 'blob':
        owner, repo, _, branch = parts[:4]
        rest = '/'.join(parts[4:])
        return f'https://raw.githubusercontent.com/{owner}/{repo}/{branch}/{rest}'
    return url


def fetch_url_text(url, max_chars=20000):
    target = github_raw_url(google_drive_download_url(url.strip()))
    req = urllib.request.Request(target, headers={'User-Agent': 'InterviewAssistant/1.0'})
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = resp.read(max_chars)
        content_type = resp.headers.get('Content-Type', '')
    if 'pdf' in content_type.lower() or target.lower().endswith('.pdf'):
        with tempfile.NamedTemporaryFile(suffix='.pdf', delete=False) as f:
            f.write(data)
            tmp_path = f.name
        try:
            return extract_pdf_text(tmp_path)[:max_chars]
        finally:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
    return data.decode('utf-8', errors='replace')[:max_chars]


def messages_to_prompt(system_prompt, question):
    return f"{system_prompt}\n\nInterview question: {question}"


def parse_responses_text(payload):
    if isinstance(payload, dict):
        if payload.get('output_text'):
            return payload['output_text']
        if payload.get('content') and isinstance(payload['content'], list):
            return ''.join(
                item.get('text', '') for item in payload['content']
                if isinstance(item, dict)
            )
        if payload.get('output') and isinstance(payload['output'], list):
            pieces = []
            for item in payload['output']:
                for content in item.get('content', []):
                    if isinstance(content, dict):
                        pieces.append(content.get('text', ''))
            if pieces:
                return ''.join(pieces)
    return json.dumps(payload, ensure_ascii=False)[:1000]


def call_ai_model(db, system_prompt, question):
    config = db.get_api_config()
    provider = config['provider']
    api_url = config['api_url']
    api_key = config['api_key'] or 'ollama'
    model = config['model']

    if provider == 'claude':
        body = {
            'model': model,
            'max_tokens': 300,
            'system': system_prompt,
            'messages': [{'role': 'user', 'content': question}]
        }
        req = urllib.request.Request(
            api_url,
            data=json.dumps(body).encode('utf-8'),
            headers={
                'Content-Type': 'application/json',
                'x-api-key': api_key,
                'anthropic-version': '2023-06-01'
            }
        )
        with urllib.request.urlopen(req, timeout=60) as resp:
            payload = json.loads(resp.read().decode('utf-8'))
        return ''.join(item.get('text', '') for item in payload.get('content', []))

    if api_url.rstrip('/').endswith('/responses'):
        body = {
            'model': model,
            'input': messages_to_prompt(system_prompt, question),
            'max_output_tokens': 300
        }
        req = urllib.request.Request(
            api_url,
            data=json.dumps(body).encode('utf-8'),
            headers={
                'Content-Type': 'application/json',
                'Authorization': f'Bearer {api_key}'
            }
        )
        with urllib.request.urlopen(req, timeout=60) as resp:
            payload = json.loads(resp.read().decode('utf-8'))
        return parse_responses_text(payload).strip()

    client = OpenAI(base_url=normalize_api_base(api_url), api_key=api_key)
    resp = client.chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": f"Interview question: {question}"}
        ],
        max_tokens=300,
    )
    return resp.choices[0].message.content.strip()


class InterviewDatabase:
    def __init__(self, path=DB_PATH):
        self.path = path
        self.lock = threading.Lock()
        self.init_schema()

    def connect(self):
        conn = sqlite3.connect(self.path)
        conn.execute("PRAGMA foreign_keys = ON")
        conn.row_factory = sqlite3.Row
        return conn

    def init_schema(self):
        with self.lock, self.connect() as conn:
            conn.executescript("""
                CREATE TABLE IF NOT EXISTS knowledge_bases (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL,
                    description TEXT DEFAULT '',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS knowledge_entries (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    kb_id INTEGER NOT NULL,
                    title TEXT NOT NULL,
                    content TEXT NOT NULL,
                    source TEXT DEFAULT 'manual',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    FOREIGN KEY (kb_id) REFERENCES knowledge_bases(id)
                        ON DELETE CASCADE
                );

                CREATE TABLE IF NOT EXISTS interview_sessions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    title TEXT NOT NULL,
                    role TEXT DEFAULT '',
                    context TEXT DEFAULT '',
                    active_kb_ids TEXT DEFAULT '',
                    started_at TEXT NOT NULL,
                    ended_at TEXT
                );

                CREATE TABLE IF NOT EXISTS conversation_turns (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id INTEGER NOT NULL,
                    question TEXT NOT NULL,
                    answer TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    FOREIGN KEY (session_id) REFERENCES interview_sessions(id)
                        ON DELETE CASCADE
                );

                CREATE TABLE IF NOT EXISTS app_settings (
                    key TEXT PRIMARY KEY,
                    value TEXT DEFAULT ''
                );
            """)
            count = conn.execute(
                "SELECT COUNT(*) FROM knowledge_bases"
            ).fetchone()[0]
            if count == 0:
                ts = now_iso()
                conn.execute(
                    "INSERT INTO knowledge_bases "
                    "(name, description, created_at, updated_at) "
                    "VALUES (?, ?, ?, ?)",
                    ('UI/UX 经历', '你的 UI/UX 项目、方法论、作品集故事', ts, ts)
                )
                conn.execute(
                    "INSERT INTO knowledge_bases "
                    "(name, description, created_at, updated_at) "
                    "VALUES (?, ?, ?, ?)",
                    ('其他经历', '其他岗位、项目或通用面试素材', ts, ts)
                )

    def list_knowledge_bases(self):
        with self.lock, self.connect() as conn:
            rows = conn.execute(
                "SELECT * FROM knowledge_bases ORDER BY updated_at DESC, id DESC"
            ).fetchall()
            return [dict(row) for row in rows]

    def get_knowledge_base(self, kb_id):
        with self.lock, self.connect() as conn:
            row = conn.execute(
                "SELECT * FROM knowledge_bases WHERE id = ?", (kb_id,)
            ).fetchone()
            return dict(row) if row else None

    def create_knowledge_base(self, name='新知识库', description=''):
        ts = now_iso()
        with self.lock, self.connect() as conn:
            cur = conn.execute(
                "INSERT INTO knowledge_bases "
                "(name, description, created_at, updated_at) "
                "VALUES (?, ?, ?, ?)",
                (name, description, ts, ts)
            )
            return cur.lastrowid

    def update_knowledge_base(self, kb_id, name, description, content):
        ts = now_iso()
        with self.lock, self.connect() as conn:
            conn.execute(
                "UPDATE knowledge_bases SET name = ?, description = ?, "
                "updated_at = ? WHERE id = ?",
                (name, description, ts, kb_id)
            )
            entry = conn.execute(
                "SELECT id FROM knowledge_entries "
                "WHERE kb_id = ? AND title = '主要内容'",
                (kb_id,)
            ).fetchone()
            if entry:
                conn.execute(
                    "UPDATE knowledge_entries SET content = ?, updated_at = ? "
                    "WHERE id = ?",
                    (content, ts, entry['id'])
                )
            elif content.strip():
                conn.execute(
                    "INSERT INTO knowledge_entries "
                    "(kb_id, title, content, source, created_at, updated_at) "
                    "VALUES (?, ?, ?, ?, ?, ?)",
                    (kb_id, '主要内容', content, 'manual', ts, ts)
                )

    def delete_knowledge_base(self, kb_id):
        with self.lock, self.connect() as conn:
            conn.execute("DELETE FROM knowledge_bases WHERE id = ?", (kb_id,))

    def add_knowledge_entry(self, kb_id, title, content, source='manual'):
        ts = now_iso()
        with self.lock, self.connect() as conn:
            conn.execute(
                "INSERT INTO knowledge_entries "
                "(kb_id, title, content, source, created_at, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (kb_id, title, content, source, ts, ts)
            )
            conn.execute(
                "UPDATE knowledge_bases SET updated_at = ? WHERE id = ?",
                (ts, kb_id)
            )

    def list_knowledge_entries(self, kb_id):
        with self.lock, self.connect() as conn:
            rows = conn.execute(
                "SELECT id, title, source, created_at FROM knowledge_entries "
                "WHERE kb_id = ? ORDER BY id DESC",
                (kb_id,)
            ).fetchall()
            return [dict(row) for row in rows]

    def get_kb_content(self, kb_id):
        with self.lock, self.connect() as conn:
            rows = conn.execute(
                "SELECT title, content FROM knowledge_entries "
                "WHERE kb_id = ? ORDER BY id",
                (kb_id,)
            ).fetchall()
            return '\n\n'.join(
                f"{row['title']}:\n{row['content']}" for row in rows
                if row['content'].strip()
            )

    def get_kb_edit_content(self, kb_id):
        with self.lock, self.connect() as conn:
            row = conn.execute(
                "SELECT content FROM knowledge_entries "
                "WHERE kb_id = ? AND title = '主要内容'",
                (kb_id,)
            ).fetchone()
            if row:
                return row['content']
            rows = conn.execute(
                "SELECT content FROM knowledge_entries "
                "WHERE kb_id = ? ORDER BY id",
                (kb_id,)
            ).fetchall()
            return '\n\n'.join(row['content'] for row in rows)

    def build_knowledge_context(self, kb_ids):
        parts = []
        for kb_id in kb_ids:
            kb = self.get_knowledge_base(kb_id)
            if not kb:
                continue
            content = self.get_kb_content(kb_id)
            if content.strip():
                parts.append(f"[{kb['name']}]\n{content}")
        return '\n\n'.join(parts)

    def create_session(self, role, context, active_kb_ids):
        ts = now_iso()
        title_role = role if role and not role.startswith('e.g.') else '本地面试'
        title = f"{ts} - {title_role}"
        with self.lock, self.connect() as conn:
            cur = conn.execute(
                "INSERT INTO interview_sessions "
                "(title, role, context, active_kb_ids, started_at) "
                "VALUES (?, ?, ?, ?, ?)",
                (title, role, context, ','.join(map(str, active_kb_ids)), ts)
            )
            return cur.lastrowid

    def update_session_kbs(self, session_id, active_kb_ids):
        with self.lock, self.connect() as conn:
            conn.execute(
                "UPDATE interview_sessions SET active_kb_ids = ? WHERE id = ?",
                (','.join(map(str, active_kb_ids)), session_id)
            )

    def finish_session(self, session_id):
        with self.lock, self.connect() as conn:
            conn.execute(
                "UPDATE interview_sessions SET ended_at = ? WHERE id = ? "
                "AND ended_at IS NULL",
                (now_iso(), session_id)
            )

    def add_turn(self, session_id, question, answer):
        with self.lock, self.connect() as conn:
            conn.execute(
                "INSERT INTO conversation_turns "
                "(session_id, question, answer, created_at) "
                "VALUES (?, ?, ?, ?)",
                (session_id, question, answer, now_iso())
            )

    def list_sessions(self):
        with self.lock, self.connect() as conn:
            rows = conn.execute(
                "SELECT s.*, COUNT(t.id) AS turn_count "
                "FROM interview_sessions s "
                "LEFT JOIN conversation_turns t ON t.session_id = s.id "
                "GROUP BY s.id ORDER BY s.started_at DESC"
            ).fetchall()
            return [dict(row) for row in rows]

    def get_session_turns(self, session_id):
        with self.lock, self.connect() as conn:
            rows = conn.execute(
                "SELECT * FROM conversation_turns "
                "WHERE session_id = ? ORDER BY created_at ASC, id ASC",
                (session_id,)
            ).fetchall()
            return [dict(row) for row in rows]

    def delete_session(self, session_id):
        with self.lock, self.connect() as conn:
            conn.execute("DELETE FROM interview_sessions WHERE id = ?", (session_id,))

    def get_setting(self, key, default=''):
        with self.lock, self.connect() as conn:
            row = conn.execute(
                "SELECT value FROM app_settings WHERE key = ?", (key,)
            ).fetchone()
            return row['value'] if row else default

    def set_setting(self, key, value):
        with self.lock, self.connect() as conn:
            conn.execute(
                "INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)",
                (key, value)
            )

    def get_api_config(self):
        provider = self.get_setting('api_provider', 'ollama') or 'ollama'
        defaults = PROVIDERS.get(provider, PROVIDERS['ollama'])
        return {
            'provider': provider,
            'api_url': self.get_setting('api_url', defaults['url']) or defaults['url'],
            'api_key': self.get_setting('api_key', ''),
            'model': self.get_setting('api_model', defaults['model']) or defaults['model'],
        }

    def save_api_config(self, provider, api_url, api_key, model):
        self.set_setting('api_provider', provider)
        self.set_setting('api_url', api_url)
        self.set_setting('api_key', api_key)
        self.set_setting('api_model', model)


class KnowledgeManagerWindow:
    def __init__(self, parent, db, active_kb_ids=None, on_active_change=None):
        self.parent = parent
        self.db = db
        self.active_kb_ids = set(active_kb_ids or [])
        self.on_active_change = on_active_change
        self.current_kb_id = None

        self.win = tk.Toplevel(parent)
        self.win.title("知识库")
        self.win.geometry('980x660')
        self.win.minsize(700, 500)
        self.win.configure(bg=THEME_BG)
        self.win.attributes('-topmost', True)
        self.win.protocol('WM_DELETE_WINDOW', self._close)
        self._build()
        self._reload()

    def _build(self):
        shell = tk.Frame(self.win, bg=THEME_BG)
        shell.pack(fill='both', expand=True, padx=18, pady=18)

        left = tk.Frame(shell, bg=THEME_PANEL, width=240,
                        highlightthickness=1, highlightbackground=THEME_BORDER)
        left.pack(side='left', fill='y')
        left.pack_propagate(False)

        tk.Label(left, text='Knowledge Library', bg=THEME_PANEL, fg=THEME_TEXT,
                 font=('PingFang SC', 15, 'bold')).pack(anchor='w', padx=14, pady=(14, 8))

        self.kb_list = tk.Listbox(left, bg=THEME_FIELD, fg=THEME_TEXT,
                                  selectbackground=THEME_BUTTON, relief='flat',
                                  highlightthickness=0, exportselection=False,
                                  font=('PingFang SC', 12))
        self.kb_list.pack(fill='both', expand=True, padx=12, pady=6)
        self.kb_list.bind('<<ListboxSelect>>', self._on_select)

        btn_row = tk.Frame(left, bg=THEME_PANEL)
        btn_row.pack(fill='x', padx=12, pady=(0, 12))
        self._label_button(btn_row, '新增', self._new_kb).pack(side='left', fill='x', expand=True, padx=(0, 4))
        self._label_button(btn_row, '删除', self._delete_kb, fg='#FF6B6B').pack(side='left', fill='x', expand=True, padx=(4, 0))

        right = tk.Frame(shell, bg=THEME_PANEL,
                         highlightthickness=1, highlightbackground=THEME_BORDER)
        right.pack(side='right', fill='both', expand=True, padx=(14, 0))

        top = tk.Frame(right, bg=THEME_PANEL)
        top.pack(fill='x', padx=16, pady=(16, 8))
        tk.Label(top, text='本次面试调用', bg=THEME_PANEL, fg=THEME_MUTED,
                 font=('PingFang SC', 11)).pack(side='left')
        self._label_button(top, '保存知识库', self._save_kb,
                           bg=THEME_ACCENT, fg=THEME_BG).pack(side='right')
        self.active_frame = tk.Frame(right, bg=THEME_PANEL)
        self.active_frame.pack(fill='x', padx=14)

        tk.Label(right, text='名称', bg=THEME_PANEL, fg=THEME_MUTED,
                 font=('PingFang SC', 11)).pack(anchor='w', padx=16, pady=(10, 2))
        self.name_entry = tk.Entry(right, bg=THEME_FIELD, fg=THEME_TEXT,
                                   insertbackground='white', relief='flat',
                                   font=('PingFang SC', 13),
                                   highlightthickness=1, highlightbackground=THEME_BORDER)
        self.name_entry.pack(fill='x', padx=16, ipady=6)

        tk.Label(right, text='说明', bg=THEME_PANEL, fg=THEME_MUTED,
                 font=('PingFang SC', 11)).pack(anchor='w', padx=16, pady=(10, 2))
        self.desc_entry = tk.Entry(right, bg=THEME_FIELD, fg=THEME_TEXT,
                                   insertbackground='white', relief='flat',
                                   font=('PingFang SC', 12),
                                   highlightthickness=1, highlightbackground=THEME_BORDER)
        self.desc_entry.pack(fill='x', padx=16, ipady=6)

        lib_row = tk.Frame(right, bg=THEME_PANEL)
        lib_row.pack(fill='x', padx=16, pady=(12, 6))
        tk.Label(lib_row, text='Library Sources', bg=THEME_PANEL, fg=THEME_MUTED,
                 font=('PingFang SC', 11)).pack(side='left')
        self._label_button(lib_row, '上传 PDF', self._upload_pdf).pack(side='right', padx=(8, 0))
        self._label_button(lib_row, '导入链接', self._import_link).pack(side='right')

        url_row = tk.Frame(right, bg=THEME_PANEL)
        url_row.pack(fill='x', padx=16, pady=(0, 8))
        self.url_entry = tk.Entry(url_row, bg=THEME_FIELD, fg=THEME_TEXT,
                                  insertbackground='white', relief='flat',
                                  font=('PingFang SC', 11),
                                  highlightthickness=1, highlightbackground=THEME_BORDER)
        self.url_entry.pack(fill='x', ipady=5)
        self.url_entry.insert(0, 'Google Drive / GitHub / PDF URL')

        self.source_list = tk.Listbox(right, bg=THEME_FIELD, fg=THEME_MUTED,
                                      selectbackground=THEME_BUTTON, relief='flat',
                                      highlightthickness=0, height=4,
                                      exportselection=False, font=('PingFang SC', 10))
        self.source_list.pack(fill='x', padx=16, pady=(0, 8))

        tk.Label(right, text='内容', bg=THEME_PANEL, fg=THEME_MUTED,
                 font=('PingFang SC', 11)).pack(anchor='w', padx=16, pady=(4, 2))
        self.content_text = scrolledtext.ScrolledText(
            right, bg=THEME_FIELD, fg=THEME_TEXT, insertbackground='white',
            relief='flat', wrap='word', font=('PingFang SC', 12), height=14
        )
        self.content_text.pack(fill='both', expand=True, padx=16, pady=(0, 16))

    def _label_button(self, parent, text, command, bg=THEME_BUTTON, fg=THEME_TEXT):
        label = tk.Label(parent, text=text, bg=bg, fg=fg,
                         font=('PingFang SC', 11), cursor='hand2',
                         padx=12, pady=7)
        label.bind('<Button-1>', lambda e: command())
        return label

    def _reload(self, select_id=None):
        self.bases = self.db.list_knowledge_bases()
        self.kb_list.delete(0, 'end')
        for kb in self.bases:
            mark = '✓ ' if kb['id'] in self.active_kb_ids else ''
            self.kb_list.insert('end', f"{mark}{kb['name']}")
        self._render_active_checks()
        if self.bases:
            target = select_id or self.current_kb_id or self.bases[0]['id']
            index = next((i for i, kb in enumerate(self.bases)
                          if kb['id'] == target), 0)
            self.kb_list.selection_clear(0, 'end')
            self.kb_list.selection_set(index)
            self.kb_list.activate(index)
            self._load_kb(self.bases[index]['id'])
        else:
            self.current_kb_id = None
            self.name_entry.delete(0, 'end')
            self.desc_entry.delete(0, 'end')
            self.content_text.delete('1.0', 'end')
            self.source_list.delete(0, 'end')

    def _render_active_checks(self):
        for child in self.active_frame.winfo_children():
            child.destroy()
        for kb in self.bases:
            var = tk.BooleanVar(value=kb['id'] in self.active_kb_ids)
            chk = tk.Checkbutton(
                self.active_frame, text=kb['name'], variable=var,
                bg='#0d0d0d', fg='#ddd', selectcolor='#222',
                activebackground=THEME_PANEL, activeforeground=THEME_TEXT,
                font=('PingFang SC', 10),
                command=lambda kid=kb['id'], v=var: self._toggle_active(kid, v)
            )
            chk.pack(side='left', padx=(0, 10), pady=2)

    def _toggle_active(self, kb_id, var):
        if var.get():
            self.active_kb_ids.add(kb_id)
        else:
            self.active_kb_ids.discard(kb_id)
        if self.on_active_change:
            self.on_active_change(sorted(self.active_kb_ids))
        self._reload(select_id=self.current_kb_id)

    def _on_select(self, _event=None):
        sel = self.kb_list.curselection()
        if sel:
            self._load_kb(self.bases[sel[0]]['id'])

    def _load_kb(self, kb_id):
        kb = self.db.get_knowledge_base(kb_id)
        if not kb:
            return
        self.current_kb_id = kb_id
        self.name_entry.delete(0, 'end')
        self.name_entry.insert(0, kb['name'])
        self.desc_entry.delete(0, 'end')
        self.desc_entry.insert(0, kb['description'] or '')
        self.content_text.delete('1.0', 'end')
        self.content_text.insert('1.0', self.db.get_kb_edit_content(kb_id))
        self._reload_sources(kb_id)

    def _reload_sources(self, kb_id):
        self.source_list.delete(0, 'end')
        for entry in self.db.list_knowledge_entries(kb_id):
            self.source_list.insert(
                'end',
                f"{entry['source']} · {entry['title']} · {entry['created_at']}"
            )

    def _new_kb(self):
        kb_id = self.db.create_knowledge_base()
        self.active_kb_ids.add(kb_id)
        if self.on_active_change:
            self.on_active_change(sorted(self.active_kb_ids))
        self._reload(select_id=kb_id)

    def _delete_kb(self):
        if not self.current_kb_id:
            return
        if not messagebox.askyesno('删除知识库', '确定删除当前知识库吗？',
                                   parent=self.win):
            return
        self.db.delete_knowledge_base(self.current_kb_id)
        self.active_kb_ids.discard(self.current_kb_id)
        if self.on_active_change:
            self.on_active_change(sorted(self.active_kb_ids))
        self.current_kb_id = None
        self._reload()

    def _save_kb(self):
        if not self.current_kb_id:
            return
        name = self.name_entry.get().strip() or '未命名知识库'
        desc = self.desc_entry.get().strip()
        content = self.content_text.get('1.0', 'end-1c').strip()
        self.db.update_knowledge_base(self.current_kb_id, name, desc, content)
        self._reload(select_id=self.current_kb_id)

    def _append_content(self, title, content, source):
        if not self.current_kb_id or not content.strip():
            return
        self.db.add_knowledge_entry(self.current_kb_id, title, content.strip(), source)
        self._reload_sources(self.current_kb_id)
        messagebox.showinfo('导入完成', f'已加入 Library: {title}', parent=self.win)

    def _upload_pdf(self):
        if not self.current_kb_id:
            return
        path = filedialog.askopenfilename(
            title='选择知识库 PDF',
            filetypes=[('PDF files', '*.pdf')]
        )
        if not path:
            return
        try:
            text = extract_pdf_text(path)
            self._append_content(os.path.basename(path), text[:12000], 'pdf')
        except ImportError:
            messagebox.showerror('缺少依赖', '请先 pip install pypdf', parent=self.win)
        except Exception as ex:
            messagebox.showerror('PDF 导入失败', str(ex), parent=self.win)

    def _import_link(self):
        if not self.current_kb_id:
            return
        url = self.url_entry.get().strip()
        if not url or url.startswith('Google Drive'):
            return
        try:
            text = fetch_url_text(url)
            title = urllib.parse.urlparse(url).netloc or '链接内容'
            self._append_content(title, text, url)
        except Exception as ex:
            messagebox.showerror('链接导入失败', str(ex), parent=self.win)

    def _close(self):
        if self.on_active_change:
            self.on_active_change(sorted(self.active_kb_ids))
        self.win.destroy()


class HistoryWindow:
    def __init__(self, parent, db):
        self.db = db
        self.win = tk.Toplevel(parent)
        self.win.title("面试历史")
        self.win.geometry('980x660')
        self.win.minsize(760, 500)
        self.win.configure(bg=THEME_BG)
        self.win.attributes('-topmost', True)
        self._build()
        self._reload()

    def _build(self):
        shell = tk.Frame(self.win, bg=THEME_BG)
        shell.pack(fill='both', expand=True, padx=18, pady=18)

        left = tk.Frame(shell, bg=THEME_PANEL, width=300,
                        highlightthickness=1, highlightbackground=THEME_BORDER)
        left.pack(side='left', fill='y')
        left.pack_propagate(False)
        tk.Label(left, text='Interview History', bg=THEME_PANEL, fg=THEME_TEXT,
                 font=('PingFang SC', 15, 'bold')).pack(anchor='w', padx=14, pady=(14, 8))
        self.session_list = tk.Listbox(left, bg=THEME_FIELD, fg=THEME_TEXT,
                                       selectbackground=THEME_BUTTON, relief='flat',
                                       highlightthickness=0, exportselection=False,
                                       font=('PingFang SC', 11))
        self.session_list.pack(fill='both', expand=True, padx=12, pady=(0, 10))
        self.session_list.bind('<<ListboxSelect>>', self._on_select)

        action_row = tk.Frame(left, bg=THEME_PANEL)
        action_row.pack(fill='x', padx=12, pady=(0, 12))
        self._button(action_row, '删除历史', self._delete_selected,
                     fg='#FF6B6B').pack(fill='x')

        right = tk.Frame(shell, bg=THEME_PANEL,
                         highlightthickness=1, highlightbackground=THEME_BORDER)
        right.pack(side='right', fill='both', expand=True, padx=(14, 0))
        tk.Label(right, text='对话详情', bg=THEME_PANEL, fg=THEME_TEXT,
                 font=('PingFang SC', 15, 'bold')).pack(anchor='w', padx=16, pady=(16, 8))
        self.detail = scrolledtext.ScrolledText(
            right, bg=THEME_FIELD, fg=THEME_TEXT, insertbackground='white',
            relief='flat', wrap='word', font=('PingFang SC', 12)
        )
        self.detail.pack(fill='both', expand=True, padx=16, pady=(0, 16))
        self.detail.configure(state='disabled')

    def _button(self, parent, text, command, bg=THEME_BUTTON, fg=THEME_TEXT):
        label = tk.Label(parent, text=text, bg=bg, fg=fg,
                         font=('PingFang SC', 11), cursor='hand2',
                         padx=12, pady=8)
        label.bind('<Button-1>', lambda e: command())
        return label

    def _reload(self):
        self.sessions = self.db.list_sessions()
        self.session_list.delete(0, 'end')
        for session in self.sessions:
            label = f"{session['started_at']}  ({session['turn_count']}轮)"
            role = session.get('role') or ''
            if role and not role.startswith('e.g.'):
                label += f"  {role[:24]}"
            self.session_list.insert('end', label)
        if self.sessions:
            self.session_list.selection_set(0)
            self._load_session(self.sessions[0]['id'])
        else:
            self._show_detail("暂无历史记录。")

    def _on_select(self, _event=None):
        sel = self.session_list.curselection()
        if sel:
            self._load_session(self.sessions[sel[0]]['id'])

    def _load_session(self, session_id):
        session = next((s for s in self.sessions if s['id'] == session_id), None)
        turns = self.db.get_session_turns(session_id)
        lines = []
        if session:
            lines.append(f"开始时间: {session['started_at']}")
            lines.append(f"结束时间: {session['ended_at'] or '进行中'}")
            if session.get('role') and not session['role'].startswith('e.g.'):
                lines.append(f"岗位: {session['role']}")
            lines.append("")
        if not turns:
            lines.append("这次面试还没有 AI 问答记录。")
        for i, turn in enumerate(turns, 1):
            lines.append(f"Q{i} [{turn['created_at']}]\n{turn['question']}")
            lines.append(f"\nAI\n{turn['answer']}")
            lines.append("\n" + "-" * 48 + "\n")
        self.detail.configure(state='normal')
        self.detail.delete('1.0', 'end')
        self.detail.insert('1.0', '\n'.join(lines))
        self.detail.configure(state='disabled')

    def _show_detail(self, text):
        self.detail.configure(state='normal')
        self.detail.delete('1.0', 'end')
        self.detail.insert('1.0', text)
        self.detail.configure(state='disabled')

    def _delete_selected(self):
        sel = self.session_list.curselection()
        if not sel:
            return
        session = self.sessions[sel[0]]
        if not messagebox.askyesno('删除历史', '确定删除这条面试历史吗？',
                                   parent=self.win):
            return
        self.db.delete_session(session['id'])
        self._reload()


# ══════════════════════════════════════════
#  启动配置窗口
# ══════════════════════════════════════════
class SetupWindow:
    """启动时填写面试背景，返回 context 字符串"""

    def __init__(self, db):
        self.db = db
        self.result = None
        self.active_kb_ids = set()
        self.used_default_kb_selection = False
        self.kb_vars = {}
        self.root = tk.Tk()
        self.root.title("面试助手 — 背景配置")
        self.root.configure(bg='#0d0d0d')
        self.root.geometry('720x760')
        self.root.minsize(560, 520)
        self.root.resizable(True, True)
        self.root.attributes('-topmost', True)
        self.pdf_text = ''
        self._build()

    def _build(self):
        outer = tk.Frame(self.root, bg='#0d0d0d')
        outer.pack(fill='both', expand=True)

        self.canvas = tk.Canvas(outer, bg='#0d0d0d', highlightthickness=0)
        self.canvas.pack(side='left', fill='both', expand=True)

        scrollbar = tk.Scrollbar(outer, orient='vertical', command=self.canvas.yview)
        scrollbar.pack(side='right', fill='y')
        self.canvas.configure(yscrollcommand=scrollbar.set)

        self.content = tk.Frame(self.canvas, bg='#0d0d0d')
        self.content_window = self.canvas.create_window(
            (0, 0), window=self.content, anchor='nw'
        )
        self.content.bind('<Configure>', self._update_scroll_region)
        self.canvas.bind('<Configure>', self._resize_content)
        self.canvas.bind_all('<MouseWheel>', self._on_mousewheel)
        self.canvas.bind_all('<Button-4>', self._on_mousewheel)
        self.canvas.bind_all('<Button-5>', self._on_mousewheel)

        tk.Label(self.content, text='🎯 面试助手 — 背景配置',
                 bg='#0d0d0d', fg='#FFE566',
                 font=('PingFang SC', 16, 'bold')).pack(padx=16, pady=(16, 4))

        tk.Label(self.content, text='填写后 AI 将基于你的背景回答面试问题',
                 bg='#0d0d0d', fg='#666',
                 font=('PingFang SC', 11)).pack()

        # 职位
        self._section('应聘职位 / Role')
        self.role_entry = tk.Entry(self.content, bg='#1a1a1a', fg='#fff',
                                   insertbackground='white',
                                   font=('PingFang SC', 13), relief='flat')
        self.role_entry.pack(fill='x', padx=16, ipady=6)
        self.role_entry.insert(0, 'e.g. Data Scientist at Google')

        # 背景文字
        self._section('项目/经历背景（可粘贴简历内容）')
        self.bg_text = scrolledtext.ScrolledText(
            self.content, bg='#1a1a1a', fg='#ccc', insertbackground='white',
            font=('PingFang SC', 12), relief='flat', height=8, wrap='word'
        )
        self.bg_text.pack(fill='x', padx=16)
        self.bg_text.insert('1.0', 'Paste your resume, project descriptions, key achievements...')
        self.bg_text.bind('<FocusIn>', self._clear_placeholder_bg)

        # PDF 上传
        self._section('上传简历 PDF（可选）')
        pdf_row = tk.Frame(self.content, bg='#0d0d0d')
        pdf_row.pack(fill='x', padx=16)

        self.pdf_label = tk.Label(pdf_row, text='未选择文件', bg='#0d0d0d',
                                   fg='#555', font=('PingFang SC', 11))
        self.pdf_label.pack(side='left')

        btn = tk.Label(pdf_row, text='📎 选择 PDF', bg='#2a2a2a', fg='#aaa',
                       font=('PingFang SC', 11), cursor='hand2', padx=10, pady=4)
        btn.pack(side='right')
        btn.bind('<Button-1>', self._pick_pdf)

        # 知识库选择
        self._section('调用知识库（可多选）')
        kb_row = tk.Frame(self.content, bg='#0d0d0d')
        kb_row.pack(fill='x', padx=16)
        self.kb_frame = tk.Frame(kb_row, bg='#0d0d0d')
        self.kb_frame.pack(side='left', fill='x', expand=True)

        kb_btn = tk.Label(kb_row, text='管理知识库', bg='#2a2a2a', fg='#aaa',
                          font=('PingFang SC', 11), cursor='hand2',
                          padx=10, pady=4)
        kb_btn.pack(side='right', padx=(8, 0))
        kb_btn.bind('<Button-1>', self._open_kb_manager)
        self._refresh_kb_options()

        # 开始按钮
        start = tk.Label(self.content, text='▶  开始面试助手', bg='#FFE566', fg='#000',
                         font=('PingFang SC', 14, 'bold'), cursor='hand2', pady=10)
        start.pack(fill='x', padx=16, pady=16)
        start.bind('<Button-1>', self._submit)

        # 跳过
        skip = tk.Label(self.content, text='跳过，直接进入提词器', bg='#0d0d0d', fg='#444',
                        font=('PingFang SC', 10), cursor='hand2')
        skip.pack(pady=(0, 10))
        skip.bind('<Button-1>', lambda e: self._submit(skip=True))

    def _section(self, title):
        tk.Label(self.content, text=title, bg='#0d0d0d', fg='#888',
                 font=('PingFang SC', 11)).pack(anchor='w', padx=16, pady=(10, 2))

    def _update_scroll_region(self, e=None):
        self.canvas.configure(scrollregion=self.canvas.bbox('all'))

    def _resize_content(self, e):
        self.canvas.itemconfigure(self.content_window, width=e.width)

    def _on_mousewheel(self, e):
        if e.num == 4:
            self.canvas.yview_scroll(-1, 'units')
        elif e.num == 5:
            self.canvas.yview_scroll(1, 'units')
        else:
            self.canvas.yview_scroll(int(-1 * (e.delta / 120)), 'units')

    def _clear_placeholder_bg(self, e):
        if self.bg_text.get('1.0', 'end-1c').startswith('Paste your resume'):
            self.bg_text.delete('1.0', 'end')
            self.bg_text.configure(fg='#ccc')

    def _pick_pdf(self, e=None):
        path = filedialog.askopenfilename(
            title='选择简历 PDF',
            filetypes=[('PDF files', '*.pdf')]
        )
        if path:
            try:
                from pypdf import PdfReader
                reader = PdfReader(path)
                self.pdf_text = '\n'.join(
                    page.extract_text() or '' for page in reader.pages
                )
                name = os.path.basename(path)
                self.pdf_label.configure(text=f'✅ {name}', fg='#5CFF8A')
            except ImportError:
                self.pdf_label.configure(
                    text='⚠️ 请先 pip install pypdf', fg='#FF6B6B')
            except Exception as ex:
                self.pdf_label.configure(text=f'❌ {str(ex)[:30]}', fg='#FF6B6B')

    def _refresh_kb_options(self):
        for child in self.kb_frame.winfo_children():
            child.destroy()
        bases = self.db.list_knowledge_bases()
        if not self.active_kb_ids and not self.used_default_kb_selection:
            self.active_kb_ids = {kb['id'] for kb in bases if kb['name'] == 'UI/UX 经历'}
            self.used_default_kb_selection = True
        self.kb_vars = {}
        for kb in bases:
            var = tk.BooleanVar(value=kb['id'] in self.active_kb_ids)
            self.kb_vars[kb['id']] = var
            chk = tk.Checkbutton(
                self.kb_frame, text=kb['name'], variable=var,
                bg='#0d0d0d', fg='#ddd', selectcolor='#222',
                activebackground='#0d0d0d', activeforeground='#FFE566',
                font=('PingFang SC', 10), command=self._sync_active_kbs
            )
            chk.pack(side='left', padx=(0, 10), pady=2)

    def _sync_active_kbs(self):
        self.active_kb_ids = {
            kb_id for kb_id, var in self.kb_vars.items() if var.get()
        }

    def _open_kb_manager(self, e=None):
        self._sync_active_kbs()
        KnowledgeManagerWindow(
            self.root, self.db, self.active_kb_ids,
            on_active_change=self._set_active_kbs
        )

    def _set_active_kbs(self, kb_ids):
        self.active_kb_ids = set(kb_ids)
        self._refresh_kb_options()

    def _submit(self, e=None, skip=False):
        if skip:
            self.result = {'role': '', 'context': '', 'active_kb_ids': []}
        else:
            role = self.role_entry.get().strip()
            if role.startswith('e.g.'):
                role = ''
            bg = self.bg_text.get('1.0', 'end-1c').strip()
            if bg.startswith('Paste your resume'):
                bg = ''
            self._sync_active_kbs()
            parts = []
            if role:
                parts.append(f"Role applying for: {role}")
            if bg:
                parts.append(f"Background & Experience:\n{bg}")
            if self.pdf_text:
                parts.append(f"Resume (PDF extracted):\n{self.pdf_text[:3000]}")
            self.result = {
                'role': role,
                'context': '\n\n'.join(parts),
                'active_kb_ids': sorted(self.active_kb_ids)
            }
        self.canvas.unbind_all('<MouseWheel>')
        self.canvas.unbind_all('<Button-4>')
        self.canvas.unbind_all('<Button-5>')
        self.root.destroy()

    def run(self):
        self.root.mainloop()
        return self.result or {'role': '', 'context': '', 'active_kb_ids': []}


# ══════════════════════════════════════════
#  主提词器窗口
# ══════════════════════════════════════════
class PrompterWindow:
    def __init__(self, root, db, session_id, context='', active_kb_ids=None,
                 mode='ai', host='', on_end=None):
        self.root = root
        self.db = db
        self.session_id = session_id
        self.context = context  # 面试背景
        self.active_kb_ids = list(active_kb_ids or [])
        self.knowledge_context = self.db.build_knowledge_context(self.active_kb_ids)
        self.mode = mode
        self.host = host
        self.on_end = on_end
        self.socket = None
        self.closed = False
        self.root.title("提词器")
        self.root.overrideredirect(True)
        self.root.attributes('-topmost', True)
        self.root.attributes('-alpha', 0.93)
        self.root.configure(bg='#0d0d0d')
        self.root.geometry('900x320+100+40')

        self._drag_x = 0
        self._drag_y = 0
        self.is_pinned = True
        self.ai_enabled = False
        self.audio_source = 'mic'
        self.lang = 'en-US'
        self.ai_queue = queue.Queue()
        self.recognizer = sr.Recognizer()
        self.listening = False
        self.ai_placeholder = 'AI 弹幕会显示在这里'
        self.showing_ai_placeholder = False

        self._build_ui()
        self._show_ai_placeholder()
        self._poll_ai_queue()
        self.root.protocol('WM_DELETE_WINDOW', self._close)
        self._apply_mode(initial=True)

    def _build_ui(self):
        # ── 顶部栏 ──
        bar = tk.Frame(self.root, bg='#111', height=28)
        bar.pack(fill='x', side='top')
        bar.pack_propagate(False)

        tk.Label(bar, text='⠿ 面试提词器', bg='#111', fg='#444',
                 font=('Helvetica', 10)).pack(side='left', padx=8)

        # 背景指示
        self.ctx_indicator = tk.Label(bar, text=self._context_label(),
                                      bg='#111',
                                      fg='#5CFF8A' if self.context or self.knowledge_context else '#444',
                                      font=('Helvetica', 9))
        self.ctx_indicator.pack(side='left', padx=4)

        kb_btn = tk.Label(bar, text='知识库', bg='#222', fg='#aaa',
                          font=('Helvetica', 9), cursor='hand2', padx=7)
        kb_btn.pack(side='left', padx=3)
        kb_btn.bind('<Button-1>', self._open_kb_manager)

        history_btn = tk.Label(bar, text='历史', bg='#222', fg='#aaa',
                              font=('Helvetica', 9), cursor='hand2', padx=7)
        history_btn.pack(side='left', padx=3)
        history_btn.bind('<Button-1>', self._open_history)

        close_btn = tk.Label(bar, text='结束', bg='#1f1f1f', fg='#ddd',
                             font=('Helvetica', 10), cursor='hand2', padx=10)
        close_btn.pack(side='right', padx=8)
        close_btn.bind('<Button-1>', lambda e: self._close())

        self.pin_btn = tk.Label(bar, text='📌', bg='#111', fg='#5CFF8A',
                                font=('Helvetica', 12), cursor='hand2', padx=6)
        self.pin_btn.pack(side='right', padx=2)
        self.pin_btn.bind('<Button-1>', self._toggle_pin)

        for symbol, delta in [('A+', 2), ('A-', -2)]:
            b = tk.Label(bar, text=symbol, bg='#222', fg='#777',
                         font=('Helvetica', 9), cursor='hand2', padx=5)
            b.pack(side='right', padx=2)
            b.bind('<Button-1>', lambda e, d=delta: self._change_font(d))

        # ── 主提词区（黄色）──
        self.font_size = 20
        self.display_font = tkfont.Font(family='PingFang SC', size=self.font_size, weight='bold')
        self.ai_font = tkfont.Font(family='PingFang SC', size=13)

        self.prompt_label = tk.Label(
            self.root, text='等待提词中...',
            font=self.display_font, fg='#FFE566', bg='#0d0d0d',
            wraplength=860, justify='center', padx=10, pady=8
        )
        self.prompt_label.pack(fill='x')

        # ── 底部控制栏 ──
        ctrl = tk.Frame(self.root, bg='#111', height=30)
        ctrl.pack(fill='x', side='bottom')
        ctrl.pack_propagate(False)

        self.ai_btn = tk.Label(ctrl, text='🤖 AI: 关', bg='#1a1a1a', fg='#555',
                               font=('Helvetica', 10), cursor='hand2', padx=8)
        self.ai_btn.pack(side='left', padx=6, pady=4)
        self.ai_btn.bind('<Button-1>', self._toggle_ai)

        self.src_btn = tk.Label(ctrl, text='🎤 麦克风', bg='#1a1a1a', fg='#555',
                                font=('Helvetica', 10), cursor='hand2', padx=8)
        self.src_btn.pack(side='left', padx=4, pady=4)
        self.src_btn.bind('<Button-1>', self._toggle_source)

        self.lang_btn = tk.Label(ctrl, text='🌐 EN', bg='#1a1a1a', fg='#aaa',
                                 font=('Helvetica', 10), cursor='hand2', padx=8)
        self.lang_btn.pack(side='left', padx=4, pady=4)
        self.lang_btn.bind('<Button-1>', self._toggle_lang)

        self.mode_btn = tk.Label(ctrl, text='', bg='#1a1a1a', fg='#aaa',
                                 font=('Helvetica', 10), cursor='hand2', padx=8)
        self.mode_btn.pack(side='left', padx=4, pady=4)
        self.mode_btn.bind('<Button-1>', self._toggle_mode)

        self.status_label = tk.Label(ctrl, text='', bg='#111', fg='#444',
                                     font=('Helvetica', 9))
        self.status_label.pack(side='right', padx=8)

        # ── AI 弹幕区（绿色，支持滚动）──
        ai_frame = tk.Frame(self.root, bg='#0d0d0d')
        ai_frame.pack(fill='both', expand=True)

        self.ai_label = tk.Text(
            ai_frame, font=self.ai_font, fg='#5CFF8A', bg='#0d0d0d',
            insertbackground='white', relief='flat', wrap='word',
            padx=14, pady=4, state='disabled', cursor='arrow',
            borderwidth=0, highlightthickness=0
        )
        self.ai_label.pack(side='left', fill='both', expand=True)

        ai_scrollbar = tk.Scrollbar(ai_frame, orient='vertical', command=self.ai_label.yview)
        ai_scrollbar.pack(side='right', fill='y')
        self.ai_label.configure(yscrollcommand=ai_scrollbar.set)

        self.root.bind('<Configure>', self._on_root_resize)

        for w in [bar, self.prompt_label]:
            w.bind('<Button-1>', self._on_drag_start)
            w.bind('<B1-Motion>', self._on_drag_move)

    def _on_drag_start(self, e):
        self._drag_x = e.x_root - self.root.winfo_x()
        self._drag_y = e.y_root - self.root.winfo_y()

    def _on_drag_move(self, e):
        self.root.geometry(f'+{e.x_root - self._drag_x}+{e.y_root - self._drag_y}')

    def _change_font(self, delta):
        self.font_size = max(14, min(60, self.font_size + delta))
        self.display_font.configure(size=self.font_size)

    def _context_label(self):
        count = len(self.active_kb_ids)
        if self.context and count:
            return f'📋 背景 + {count}个知识库'
        if count:
            return f'📚 已调用 {count} 个知识库'
        if self.context:
            return '📋 背景已加载'
        return '未加载背景'

    def _refresh_knowledge_context(self):
        self.knowledge_context = self.db.build_knowledge_context(self.active_kb_ids)
        self.db.update_session_kbs(self.session_id, self.active_kb_ids)
        if hasattr(self, 'ctx_indicator'):
            self.ctx_indicator.configure(text=self._context_label())
            self.ctx_indicator.configure(
                fg='#5CFF8A' if self.context or self.knowledge_context else '#444'
            )

    def _set_active_kbs(self, kb_ids):
        self.active_kb_ids = list(kb_ids)
        self._refresh_knowledge_context()

    def _open_kb_manager(self, e=None):
        KnowledgeManagerWindow(
            self.root, self.db, self.active_kb_ids,
            on_active_change=self._set_active_kbs
        )

    def _open_history(self, e=None):
        HistoryWindow(self.root, self.db)

    def _close(self):
        if self.closed:
            return
        self.closed = True
        self.listening = False
        if self.socket:
            try:
                self.socket.close()
            except Exception:
                pass
            self.socket = None
        self.db.finish_session(self.session_id)
        self.root.destroy()
        if self.on_end:
            self.on_end()

    def _apply_mode(self, initial=False):
        if self.mode == 'ip':
            self.db.set_setting('last_mode', 'ip')
            self.mode_btn.configure(text='模式: IP 接收', fg='#FFE566')
            if initial:
                self.update_text('等待 IP 提词连接...')
            if self.host:
                self._connect_ip(self.host)
            else:
                self._ask_ip_and_connect()
        else:
            self.db.set_setting('last_mode', 'ai')
            self.mode_btn.configure(text='模式: AI 本地', fg='#5CFF8A')
            self.update_text('AI 弹幕模式')
            self._set_status('本地模式')

    def _toggle_mode(self, e=None):
        if self.mode == 'ai':
            self.mode = 'ip'
            self.db.set_setting('last_mode', 'ip')
            self._ask_ip_and_connect()
        else:
            self.mode = 'ai'
            self.db.set_setting('last_mode', 'ai')
            if self.socket:
                try:
                    self.socket.close()
                except Exception:
                    pass
                self.socket = None
            self._apply_mode()

    def _ask_ip_and_connect(self):
        host = simpledialog.askstring(
            "连接设置",
            "输入发送端 IP",
            initialvalue=self.host,
            parent=self.root
        )
        if host and host.strip():
            self.host = host.strip()
            self.db.set_setting('last_host', self.host)
            self._connect_ip(self.host)
        else:
            self.mode = 'ai'
            self._apply_mode()

    def _connect_ip(self, host):
        self.mode_btn.configure(text='模式: IP 接收', fg='#FFE566')
        self._set_status(f'连接 {host}...')
        if self.socket:
            try:
                self.socket.close()
            except Exception:
                pass
            self.socket = None
        threading.Thread(target=self._connect_and_listen,
                         args=(host,), daemon=True).start()

    def _connect_and_listen(self, host):
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.socket = s
            s.connect((host, PORT))
            self.update_text('✅ 已连接，等待提词...')
            self._set_status('IP 接收中')
            buf = ''
            while not self.closed and self.mode == 'ip':
                data = s.recv(1024).decode('utf-8')
                if not data:
                    self.update_text('⚠️ 连接已断开')
                    self._set_status('IP 已断开')
                    break
                buf += data
                while '\n' in buf:
                    line, buf = buf.split('\n', 1)
                    if line.strip():
                        self.update_text(line)
        except OSError:
            if not self.closed and self.mode == 'ip':
                self._set_status('IP 已断开')
        except Exception as e:
            if not self.closed and self.mode == 'ip':
                self.update_text(f'❌ 连接失败: {e}')
                self._set_status('IP 连接失败')

    def update_text(self, text):
        if self.closed:
            return
        self.root.after(0, lambda: self.prompt_label.configure(text=text))

    def update_ai_text(self, text, placeholder=False):
        if self.closed:
            return
        def apply():
            if self.closed:
                return
            self.showing_ai_placeholder = placeholder
            self.ai_label.configure(state='normal')
            self.ai_label.delete('1.0', 'end')
            self.ai_label.insert('1.0', text)
            self.ai_label.configure(fg='#3A3A3A' if placeholder else '#5CFF8A')
            self.ai_label.configure(state='disabled')
            self.ai_label.yview_moveto(0)
        self.root.after(0, apply)

    def _show_ai_placeholder(self):
        self.update_ai_text(self.ai_placeholder, placeholder=True)

    def _on_root_resize(self, e):
        if e.widget == self.root:
            self.prompt_label.configure(wraplength=max(240, e.width - 40))

    def _toggle_pin(self, e=None):
        self.is_pinned = not self.is_pinned
        self.root.attributes('-topmost', self.is_pinned)
        self.pin_btn.configure(fg='#5CFF8A' if self.is_pinned else '#555')

    def _toggle_lang(self, e=None):
        if self.lang == 'en-US':
            self.lang = 'zh-CN'
            self.lang_btn.configure(text='🌐 中文')
        else:
            self.lang = 'en-US'
            self.lang_btn.configure(text='🌐 EN')

    def _toggle_ai(self, e=None):
        self.ai_enabled = not self.ai_enabled
        if self.ai_enabled:
            self.ai_btn.configure(text='🤖 AI: 开', fg='#5CFF8A')
            self.listening = True
            threading.Thread(target=self._vad_loop, daemon=True).start()
        else:
            self.ai_btn.configure(text='🤖 AI: 关', fg='#555')
            self.listening = False
            self._show_ai_placeholder()
            self._set_status('')

    def _toggle_source(self, e=None):
        if self.audio_source == 'mic':
            self.audio_source = 'blackhole'
            self.src_btn.configure(text='🔊 系统声音')
        else:
            self.audio_source = 'mic'
            self.src_btn.configure(text='🎤 麦克风')

    def _get_device_index(self):
        devices = sd.query_devices()
        if self.audio_source == 'blackhole':
            for i, d in enumerate(devices):
                if 'BlackHole' in d['name'] and d['max_input_channels'] > 0:
                    return i
        return None

    def _vad_loop(self):
        CHUNK_MS = 100
        CHUNK_SAMPLES = int(SAMPLE_RATE * CHUNK_MS / 1000)
        SILENCE_THRESHOLD = 300
        SILENCE_TRIGGER_MS = 1500
        MAX_RECORD_MS = 30000

        silence_chunks = 0
        silence_limit = SILENCE_TRIGGER_MS // CHUNK_MS
        max_chunks = MAX_RECORD_MS // CHUNK_MS

        speech_buffer = []
        is_speaking = False
        device = self._get_device_index()
        self._set_status('🎙 监听中...')

        try:
            with sd.InputStream(samplerate=SAMPLE_RATE, channels=1,
                                 dtype='int16', device=device,
                                 blocksize=CHUNK_SAMPLES) as stream:
                while self.listening:
                    chunk, _ = stream.read(CHUNK_SAMPLES)
                    chunk = chunk.flatten()
                    rms = np.sqrt(np.mean(chunk.astype(np.float32) ** 2))

                    if rms > SILENCE_THRESHOLD:
                        if not is_speaking:
                            is_speaking = True
                            self._set_status('🔴 录音中...')
                        speech_buffer.append(chunk)
                        silence_chunks = 0
                        if len(speech_buffer) >= max_chunks:
                            self._trigger_recognition(speech_buffer)
                            speech_buffer = []
                            is_speaking = False
                            self._set_status('🎙 监听中...')
                    else:
                        if is_speaking:
                            speech_buffer.append(chunk)
                            silence_chunks += 1
                            if silence_chunks >= silence_limit:
                                self._trigger_recognition(speech_buffer)
                                speech_buffer = []
                                is_speaking = False
                                silence_chunks = 0
                                self._set_status('🎙 监听中...')
        except Exception as ex:
            self._set_status(f'❌ {str(ex)[:30]}')

    def _trigger_recognition(self, buffer):
        audio_np = np.concatenate(buffer).astype(np.int16)
        threading.Thread(target=self._recognize_and_ask,
                         args=(audio_np,), daemon=True).start()

    def _recognize_and_ask(self, audio_np):
        try:
            self._set_status('🔍 识别中...')
            with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as f:
                tmp_path = f.name
            wav.write(tmp_path, SAMPLE_RATE, audio_np)
            with sr.AudioFile(tmp_path) as source:
                audio = self.recognizer.record(source)
            os.unlink(tmp_path)

            text = self.recognizer.recognize_google(audio, language=self.lang)
            if text and len(text.strip()) > 1:
                self._set_status(f'💬 {text[:30]}...')
                self._ask_ai(text)
            else:
                self._set_status('🎙 监听中...')
        except sr.UnknownValueError:
            self._set_status('🎙 监听中...')
        except Exception as ex:
            self._set_status(f'⚠️ {str(ex)[:30]}')

    def _ask_ai(self, question):
        try:
            self.ai_queue.put('🤖 思考中...')

            # 构建 system prompt，融入面试背景
            system_parts = [
                "You are a real-time interview assistant helping the candidate answer questions.",
                "Give a detailed, structured answer in 60-80 words.",
                "Use bullet points or short sentences. Be specific and confident.",
                "Always reply in English unless the question is in Chinese.",
            ]
            if self.context:
                system_parts.append(
                    f"\n--- Candidate Background ---\n{self.context}\n---"
                    "\nBase your answers on this background. Reference specific projects and experiences when relevant."
                )
            if self.knowledge_context:
                system_parts.append(
                    f"\n--- Selected Knowledge Bases ---\n{self.knowledge_context}\n---"
                    "\nUse these knowledge bases when they are relevant to the question."
                )

            answer = call_ai_model(self.db, '\n'.join(system_parts), question)
            self.db.add_turn(self.session_id, question, answer)
            self.ai_queue.put(f'💡 {answer}')
        except Exception as ex:
            self.ai_queue.put(f'❌ {str(ex)[:40]}')

    def _poll_ai_queue(self):
        if self.closed:
            return
        try:
            while True:
                msg = self.ai_queue.get_nowait()
                self.update_ai_text(msg)
        except queue.Empty:
            pass
        self.root.after(200, self._poll_ai_queue)

    def _set_status(self, text):
        if self.closed:
            return
        self.root.after(0, lambda: self.status_label.configure(text=text))


def connect_and_listen(window, host):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.connect((host, PORT))
        window.update_text('✅ 已连接，等待提词...')
        buf = ''
        while True:
            data = s.recv(1024).decode('utf-8')
            if not data:
                window.update_text('⚠️ 连接已断开')
                break
            buf += data
            while '\n' in buf:
                line, buf = buf.split('\n', 1)
                if line.strip():
                    window.update_text(line)
    except Exception as e:
        window.update_text(f'❌ 连接失败: {e}')


class APIConfigWindow:
    def __init__(self, parent, db, on_save=None):
        self.parent = parent
        self.db = db
        self.on_save = on_save
        config = self.db.get_api_config()
        self.provider = tk.StringVar(value=config['provider'])
        self.api_url = tk.StringVar(value=config['api_url'])
        self.api_key = tk.StringVar(value=config['api_key'])
        self.model = tk.StringVar(value=config['model'])

        self.win = tk.Toplevel(parent)
        self.win.title("API 配置")
        self.win.geometry('820x620')
        self.win.minsize(700, 540)
        self.win.configure(bg=THEME_BG)
        self.win.attributes('-topmost', True)
        self._build()
        self._apply_provider_defaults(force=False)

    def _build(self):
        shell = tk.Frame(self.win, bg=THEME_BG)
        shell.pack(fill='both', expand=True, padx=20, pady=20)

        tk.Label(shell, text='API 配置', bg=THEME_BG, fg=THEME_TEXT,
                 font=('PingFang SC', 24, 'bold')).pack(anchor='w')
        tk.Label(shell, text='选择提供商、模型和密钥；配置会明文保存在本地 SQLite。',
                 bg=THEME_BG, fg=THEME_MUTED,
                 font=('PingFang SC', 11)).pack(anchor='w', pady=(4, 16))

        panel = tk.Frame(shell, bg=THEME_PANEL,
                         highlightthickness=1, highlightbackground=THEME_BORDER)
        panel.pack(fill='both', expand=True)

        self._label(panel, 'API 提供商')
        self.provider_button = self._menu_button(panel, self.provider)
        self.provider_button.pack(fill='x', padx=18, pady=(0, 6))
        self.provider_menu = tk.Menu(
            self.provider_button, tearoff=False, bg='#ffffff', fg='#111111',
            activebackground='#e5e7eb', activeforeground='#111111',
            relief='flat', borderwidth=0
        )
        self.provider_button.configure(menu=self.provider_menu)
        for key, meta in PROVIDERS.items():
            self.provider_menu.add_command(
                label=f"{key} · {meta['label']}",
                command=lambda value=key: self._set_provider(value)
            )
        self.provider_help = tk.Label(panel, text='', bg=THEME_PANEL,
                                      fg=THEME_MUTED, font=('PingFang SC', 10),
                                      justify='left')
        self.provider_help.pack(anchor='w', padx=18, pady=(0, 14))

        self._label(panel, 'API 地址 *')
        self.api_url_entry = self._entry(panel, self.api_url)
        self.api_url_entry.pack(fill='x', padx=18, ipady=7, pady=(0, 12))

        self._label(panel, 'API 密钥')
        key_row = tk.Frame(panel, bg=THEME_PANEL)
        key_row.pack(fill='x', padx=18, pady=(0, 12))
        self.api_key_entry = self._entry(key_row, self.api_key, show='•')
        self.api_key_entry.pack(side='left', fill='x', expand=True, ipady=7)
        self.show_key = False
        self._button(key_row, '显示', self._toggle_key).pack(side='right', padx=(8, 0))

        self._label(panel, '模型 *')
        model_row = tk.Frame(panel, bg=THEME_PANEL)
        model_row.pack(fill='x', padx=18, pady=(0, 10))
        self.model_button = self._menu_button(model_row, self.model)
        self.model_button.pack(side='left', fill='x', expand=True)
        self.model_menu = tk.Menu(
            self.model_button, tearoff=False, bg='#ffffff', fg='#111111',
            activebackground='#e5e7eb', activeforeground='#111111',
            relief='flat', borderwidth=0
        )
        self.model_button.configure(menu=self.model_menu)
        self.model_entry = self._entry(model_row, self.model)
        self.model_entry.pack(side='left', fill='x', expand=True, ipady=7, padx=(8, 0))

        note = tk.Label(
            panel,
            text='提示：火山方舟建议 API 地址填到 /api/v3；如果你明确使用 Responses API，也可以填完整 /responses 地址。',
            bg=THEME_PANEL, fg='#8fd19e', justify='left',
            font=('PingFang SC', 10), wraplength=720
        )
        note.pack(fill='x', padx=18, pady=(4, 18))

        actions = tk.Frame(panel, bg=THEME_PANEL)
        actions.pack(fill='x', padx=18, pady=(0, 18))
        self._button(actions, '保存配置', self._save,
                     bg=THEME_ACCENT, fg=THEME_BG).pack(side='right')

    def _label(self, parent, text):
        tk.Label(parent, text=text, bg=THEME_PANEL, fg=THEME_TEXT,
                 font=('PingFang SC', 12, 'bold')).pack(anchor='w', padx=18, pady=(14, 5))

    def _entry(self, parent, textvariable, show=None):
        return tk.Entry(parent, textvariable=textvariable, bg=THEME_FIELD,
                        fg=THEME_TEXT, insertbackground=THEME_TEXT,
                        relief='flat', font=('PingFang SC', 12), show=show,
                        highlightthickness=1, highlightbackground=THEME_BORDER,
                        highlightcolor='#6e7681')

    def _menu_button(self, parent, textvariable):
        return tk.Menubutton(
            parent, textvariable=textvariable, bg='#ffffff', fg='#111111',
            activebackground='#ffffff', activeforeground='#111111',
            disabledforeground='#111111',
            relief='flat', font=('PingFang SC', 12), anchor='w',
            padx=12, pady=9, highlightthickness=1,
            highlightbackground='#ffffff', highlightcolor='#ffffff',
            indicatoron=True, cursor='hand2'
        )

    def _button(self, parent, text, command, bg=THEME_BUTTON, fg=THEME_TEXT):
        label = tk.Label(parent, text=text, bg=bg, fg=fg,
                         font=('PingFang SC', 11), cursor='hand2',
                         padx=14, pady=8)
        label.bind('<Button-1>', lambda e: command())
        return label

    def _set_provider(self, value):
        self.provider.set(value)
        self._apply_provider_defaults(force=True)

    def _apply_provider_defaults(self, force=False):
        provider = self.provider.get()
        meta = PROVIDERS.get(provider, PROVIDERS['ollama'])
        if force or not self.api_url.get().strip():
            self.api_url.set(meta['url'])
        if force or not self.model.get().strip():
            self.model.set(meta['model'])
        self.provider_help.configure(text=meta['help'])
        self.model_menu.delete(0, 'end')
        for item in meta['models']:
            self.model_menu.add_command(
                label=item,
                command=lambda value=item: self.model.set(value)
            )

    def _toggle_key(self):
        self.show_key = not self.show_key
        self.api_key_entry.configure(show='' if self.show_key else '•')

    def _save(self):
        provider = self.provider.get()
        self.db.save_api_config(
            provider,
            self.api_url.get().strip(),
            self.api_key.get().strip(),
            self.model.get().strip()
        )
        if self.on_save:
            self.on_save()
        self.win.destroy()


class MainWindow:
    def __init__(self, root, db):
        self.root = root
        self.db = db
        self.root.title("Interview Assistant")
        self.root.geometry('980x680')
        self.root.minsize(860, 600)
        self.root.configure(bg='#0f1117')

        self.mode = tk.StringVar(value=self.db.get_setting('last_mode', 'ai') or 'ai')
        self.host = tk.StringVar(value=self.db.get_setting('last_host', ''))
        self.pdf_text = ''
        self.active_kb_ids = set()
        self.kb_vars = {}
        self.used_default_kb_selection = False
        self.interview_window = None

        self._build()
        self._refresh_kb_options()

    def _build(self):
        shell = tk.Frame(self.root, bg='#0f1117')
        shell.pack(fill='both', expand=True, padx=22, pady=20)

        header = tk.Frame(shell, bg='#0f1117')
        header.pack(fill='x', pady=(0, 16))
        tk.Label(header, text='Interview Assistant', bg='#0f1117',
                 fg='#f4f4f5', font=('PingFang SC', 24, 'bold')).pack(side='left')
        tk.Label(header, text='面试提示词', bg='#0f1117',
                 fg='#8b949e', font=('PingFang SC', 12)).pack(side='left', padx=14, pady=(8, 0))

        top_actions = tk.Frame(header, bg='#0f1117')
        top_actions.pack(side='right')
        self._button(top_actions, 'API 配置', self._open_api_config).pack(side='left', padx=(0, 8))
        self._button(top_actions, '历史记录', self._open_history).pack(side='left', padx=(0, 8))
        self._button(top_actions, '知识库', self._open_kb_manager).pack(side='left')

        body = tk.Frame(shell, bg='#0f1117')
        body.pack(fill='both', expand=True)

        left = self._panel(body)
        left.pack(side='left', fill='both', expand=True, padx=(0, 10))
        right = self._panel(body, width=300)
        right.pack(side='right', fill='y', padx=(10, 0))
        right.pack_propagate(False)

        tk.Label(left, text='开始一轮面试', bg='#161a22', fg='#f4f4f5',
                 font=('PingFang SC', 16, 'bold')).pack(anchor='w', padx=18, pady=(18, 4))
        tk.Label(left, text='选择模式、填写岗位和背景，然后进入提词器窗口。结束后会回到这里。',
                 bg='#161a22', fg='#8b949e',
                 font=('PingFang SC', 11)).pack(anchor='w', padx=18, pady=(0, 16))

        mode_row = tk.Frame(left, bg='#161a22')
        mode_row.pack(fill='x', padx=18, pady=(0, 14))
        self.ai_mode_btn = self._segment(mode_row, 'AI 本地模式', 'ai')
        self.ai_mode_btn.pack(side='left', fill='x', expand=True)
        self.ip_mode_btn = self._segment(mode_row, 'IP 接收模式', 'ip')
        self.ip_mode_btn.pack(side='left', fill='x', expand=True, padx=(8, 0))
        self._refresh_mode_buttons()

        self._field_label(left, '发送端 IP')
        self.host_entry = self._entry(left, self.host)
        self.host_entry.pack(fill='x', padx=18, ipady=7, pady=(0, 12))

        self._field_label(left, '应聘职位 / Role')
        self.role_entry = self._entry(left)
        self.role_entry.insert(0, 'e.g. Product Designer at Google')
        self.role_entry.pack(fill='x', padx=18, ipady=7, pady=(0, 12))

        self._field_label(left, '项目/经历背景')
        self.bg_text = scrolledtext.ScrolledText(
            left, bg='#0f1117', fg='#d4d4d8', insertbackground='#f4f4f5',
            relief='flat', wrap='word', height=9, font=('PingFang SC', 12),
            borderwidth=0, highlightthickness=1, highlightbackground='#262b36',
            highlightcolor='#6e7681'
        )
        self.bg_text.pack(fill='both', expand=True, padx=18, pady=(0, 14))
        self.bg_text.insert('1.0', 'Paste your resume, project descriptions, key achievements...')
        self.bg_text.bind('<FocusIn>', self._clear_bg_placeholder)

        action_row = tk.Frame(left, bg='#161a22')
        action_row.pack(fill='x', padx=18, pady=(0, 18))
        self.pdf_label = tk.Label(action_row, text='未选择 PDF', bg='#161a22',
                                  fg='#71717a', font=('PingFang SC', 10))
        self.pdf_label.pack(side='left')
        self._button(action_row, '上传 PDF', self._pick_pdf).pack(side='right', padx=(8, 0))
        self._button(action_row, '开始面试', self._start_interview,
                     bg='#f4f4f5', fg='#0f1117').pack(side='right')

        tk.Label(right, text='调用知识库', bg='#161a22', fg='#f4f4f5',
                 font=('PingFang SC', 15, 'bold')).pack(anchor='w', padx=16, pady=(18, 4))
        tk.Label(right, text='勾选后 AI 会优先引用这些资料。',
                 bg='#161a22', fg='#8b949e',
                 font=('PingFang SC', 10)).pack(anchor='w', padx=16, pady=(0, 12))
        self.kb_frame = tk.Frame(right, bg='#161a22')
        self.kb_frame.pack(fill='x', padx=14)

        self.history_summary = tk.Label(right, text='', bg='#161a22',
                                        fg='#8b949e', justify='left',
                                        font=('PingFang SC', 10))
        self.history_summary.pack(anchor='w', padx=16, pady=(22, 8))
        self.api_summary = tk.Label(right, text='', bg='#161a22',
                                    fg='#8b949e', justify='left',
                                    font=('PingFang SC', 10))
        self.api_summary.pack(anchor='w', padx=16, pady=(0, 8))
        self._button(right, 'API 配置', self._open_api_config).pack(fill='x', padx=16, pady=(0, 8))
        self._button(right, '查看历史记录', self._open_history).pack(fill='x', padx=16, pady=(0, 8))
        self._button(right, '管理知识库', self._open_kb_manager).pack(fill='x', padx=16)
        self._refresh_history_summary()
        self._refresh_api_summary()

    def _panel(self, parent, width=None):
        kwargs = {'bg': '#161a22', 'highlightthickness': 1,
                  'highlightbackground': '#262b36'}
        if width:
            kwargs['width'] = width
        return tk.Frame(parent, **kwargs)

    def _button(self, parent, text, command, bg='#222733', fg='#d4d4d8'):
        label = tk.Label(parent, text=text, bg=bg, fg=fg,
                         font=('PingFang SC', 11), cursor='hand2',
                         padx=14, pady=8)
        label.bind('<Button-1>', lambda e: command())
        return label

    def _segment(self, parent, text, mode):
        label = tk.Label(parent, text=text, bg='#222733', fg='#a1a1aa',
                         font=('PingFang SC', 11, 'bold'),
                         cursor='hand2', padx=14, pady=10)
        label.bind('<Button-1>', lambda e, m=mode: self._set_mode(m))
        return label

    def _field_label(self, parent, text):
        tk.Label(parent, text=text, bg='#161a22', fg='#a1a1aa',
                 font=('PingFang SC', 11)).pack(anchor='w', padx=18, pady=(0, 4))

    def _entry(self, parent, textvariable=None):
        return tk.Entry(parent, textvariable=textvariable, bg='#0f1117',
                        fg='#f4f4f5', insertbackground='#f4f4f5',
                        relief='flat', font=('PingFang SC', 12),
                        highlightthickness=1, highlightbackground='#262b36',
                        highlightcolor='#6e7681')

    def _set_mode(self, mode):
        self.mode.set(mode)
        self.db.set_setting('last_mode', mode)
        self._refresh_mode_buttons()

    def _refresh_mode_buttons(self):
        active = {'bg': '#f4f4f5', 'fg': '#0f1117'}
        inactive = {'bg': '#222733', 'fg': '#a1a1aa'}
        self.ai_mode_btn.configure(**(active if self.mode.get() == 'ai' else inactive))
        self.ip_mode_btn.configure(**(active if self.mode.get() == 'ip' else inactive))

    def _clear_bg_placeholder(self, _event=None):
        if self.bg_text.get('1.0', 'end-1c').startswith('Paste your resume'):
            self.bg_text.delete('1.0', 'end')

    def _pick_pdf(self):
        path = filedialog.askopenfilename(
            title='选择简历 PDF',
            filetypes=[('PDF files', '*.pdf')]
        )
        if not path:
            return
        try:
            from pypdf import PdfReader
            reader = PdfReader(path)
            self.pdf_text = '\n'.join(page.extract_text() or '' for page in reader.pages)
            self.pdf_label.configure(text=os.path.basename(path), fg='#5CFF8A')
        except ImportError:
            self.pdf_label.configure(text='请先 pip install pypdf', fg='#FF6B6B')
        except Exception as ex:
            self.pdf_label.configure(text=f'读取失败: {str(ex)[:30]}', fg='#FF6B6B')

    def _refresh_kb_options(self):
        for child in self.kb_frame.winfo_children():
            child.destroy()
        bases = self.db.list_knowledge_bases()
        if not self.active_kb_ids and not self.used_default_kb_selection:
            self.active_kb_ids = {kb['id'] for kb in bases if kb['name'] == 'UI/UX 经历'}
            self.used_default_kb_selection = True
        self.kb_vars = {}
        for kb in bases:
            var = tk.BooleanVar(value=kb['id'] in self.active_kb_ids)
            self.kb_vars[kb['id']] = var
            chk = tk.Checkbutton(
                self.kb_frame, text=kb['name'], variable=var,
                bg='#161a22', fg='#d4d4d8', selectcolor='#222733',
                activebackground='#161a22', activeforeground='#f4f4f5',
                font=('PingFang SC', 10), command=self._sync_active_kbs
            )
            chk.pack(anchor='w', pady=3)

    def _sync_active_kbs(self):
        self.active_kb_ids = {
            kb_id for kb_id, var in self.kb_vars.items() if var.get()
        }

    def _set_active_kbs(self, kb_ids):
        self.active_kb_ids = set(kb_ids)
        self._refresh_kb_options()

    def _open_kb_manager(self):
        self._sync_active_kbs()
        KnowledgeManagerWindow(
            self.root, self.db, self.active_kb_ids,
            on_active_change=self._set_active_kbs
        )

    def _open_history(self):
        HistoryWindow(self.root, self.db)

    def _open_api_config(self):
        APIConfigWindow(self.root, self.db, on_save=self._refresh_api_summary)

    def _refresh_history_summary(self):
        sessions = self.db.list_sessions()
        count = len(sessions)
        last = sessions[0]['started_at'] if sessions else '暂无记录'
        self.history_summary.configure(text=f'历史面试: {count} 次\n最近一次: {last}')

    def _refresh_api_summary(self):
        config = self.db.get_api_config()
        label = PROVIDERS.get(config['provider'], PROVIDERS['ollama'])['label']
        self.api_summary.configure(text=f'当前模型: {label}\n{config["model"]}')

    def _build_context(self):
        role = self.role_entry.get().strip()
        if role.startswith('e.g.'):
            role = ''
        bg = self.bg_text.get('1.0', 'end-1c').strip()
        if bg.startswith('Paste your resume'):
            bg = ''
        parts = []
        if role:
            parts.append(f"Role applying for: {role}")
        if bg:
            parts.append(f"Background & Experience:\n{bg}")
        if self.pdf_text:
            parts.append(f"Resume (PDF extracted):\n{self.pdf_text[:3000]}")
        return role, '\n\n'.join(parts)

    def _start_interview(self):
        self._sync_active_kbs()
        mode = self.mode.get()
        host = self.host.get().strip()
        self.db.set_setting('last_mode', mode)
        self.db.set_setting('last_host', host)
        role, context = self._build_context()
        active_kb_ids = sorted(self.active_kb_ids)
        session_id = self.db.create_session(role, context, active_kb_ids)

        self.root.withdraw()
        win = tk.Toplevel(self.root)
        self.interview_window = PrompterWindow(
            win, self.db, session_id,
            context=context,
            active_kb_ids=active_kb_ids,
            mode=mode,
            host=host,
            on_end=self._return_home
        )

    def _return_home(self):
        self.interview_window = None
        self.mode.set(self.db.get_setting('last_mode', self.mode.get()) or 'ai')
        self.host.set(self.db.get_setting('last_host', self.host.get()))
        self._refresh_mode_buttons()
        self._refresh_history_summary()
        self.root.deiconify()
        self.root.lift()


def main():
    db = InterviewDatabase()
    root = tk.Tk()
    MainWindow(root, db)
    root.mainloop()


if __name__ == '__main__':
    main()
