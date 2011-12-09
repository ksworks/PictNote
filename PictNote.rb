#!/usr/bin/ruby
# -*- coding: utf-8 -*-
#
# = PictNote - パラメータで指定した画像ファイルをEvernoteにアップロードする
#  JPEG画像でEXIF情報が存在する場合、その情報を収集してノート属性に設定する。
#
# USAGE:
#  ./PictNote.rb <filename>...
#    <filename> : イメージファイル名
#
# NOTE:
#  現状、動作確認しているイメージの種類は以下の通り(2011-12-08)
#  - image/png(enlogo.png)
#  - image/jpeg with GPS(EXIF)
#  - image/jepg without GPS
#
# REQUIRE:
#  rubygems: mime/types, exifr
#  Evernote API 1.19 or lator
#  [CLI] growlnotify 1.3.1 or lator
#
# SEEALSO:
#  http://www.ksworks.org/2011/11/os-x-lion-de-ruby-evernote.html
#  http://www.ksworks.org/2011/11/ruby-upload-evenote-with-jpeg.html
#  http://www.ksworks.org/2011/11/ruby-de-evernote-attributes.html
#  http://www.ksworks.org/2011/11/ruby-de-jpegexif-to-ennoteattr.html
#  http://www.ksworks.org/2011/11/remove-warn-in-edamtest-ruby.html
#  http://www.ksworks.org/2011/12/xxxx (now writing...)
#
#  Authors:: Ken AKASHI <ks at ksworks.org>
#  Version:: 2011-12-08
#  License:: NYSL Version 0.9982
#  Copyright:: Copyright (C) ksworks, 2011. All rights reserved.
#
$ScriptName = 'PictNote[Ruby]'

#
# ---- CONFIG BEGIN ----
#

# タイトル設定時の時刻情報フォーマット (strffmt)
$NoteTitleFormat = '%Y-%m-%d(%a) %H:%M:%S %Z'

# ノート情報登録成功時に通知をするか?
$NotifySuccessed = true

# ノート情報登録成功時に元ファイルを削除するか?
$RemoveFileSuccessed = false

# EVERNOTE保存先ノートブック名(デフォルトで良ければコメントアウト)
$ENStoreNotebookName = 'testnotebook'

# EVERNOTE保存時設定タグ名(設定不要ならコメントアウト)
$ENStoreTagName = [ 'testtag1', 'testtag2' ] # 設定したいタグ名を設定(複数可)

# EVERNOTE USERNAME
$EvernoteUsername = 'username'

# EVERNOTE PASSWORD
$EvernotePassword = 'password'

# EVERNOTE API Consumer Key
$EvernoteConsumerKey = 'en-edamtest'

# EVERNOTE API Consumer Key
$EvernoteConsumerSecret = '0123456789abcdef'

# EVERNOTE API Hostname
$EvernoteHost = 'sandbox.evernote.com'
#$EvernoteHost = 'www.evernote.com'

# EVERNOTE API installed directories.
$LOAD_PATH.push("/usr/lib/site_ruby")
$LOAD_PATH.push("/usr/lib/site_ruby/Evernote/EDAM")

#
# ---- CONFIG END ----
#


# CONSTANTs

$ENuserStoreUrl = "https://#{$EvernoteHost}/edam/user"
$ENnoteStoreUrlBase = "https://#{$EvernoteHost}/edam/note/"


# Load Libs

require 'rubygems'
require 'digest/md5'
require 'mime/types'
require 'exifr'

require 'thrift/types'
require 'thrift/struct'
require 'thrift/protocol/base_protocol'
require 'thrift/protocol/binary_protocol'
require 'thrift/transport/base_transport'
require 'thrift/transport/http_client_transport'
require 'Evernote/EDAM/user_store'
require 'Evernote/EDAM/user_store_constants.rb'
require 'Evernote/EDAM/note_store'
require 'Evernote/EDAM/limits_constants.rb'


#
# == EVERNOTE API関連
#  EDAM API関連の処理クラス
# SAMPLE:
#  edam = EdamApiMng.new
#  nbook = edam.selectNotebook('notebookname')
#  tag = edam.selectTag('tagname')
#  edam.createNote(ENNote.new)
#
class EdamApiMng

  #
  # === 初期化処理
  #  API関連の初期処理
  #  UserStore->NoteStoreの初期化を行う　
  #
  def initialize
    self.initUserStore
    self.initNoteStore
  end

  #
  # === UserStore初期化
  #  ユーザストア関連の初期化を行う
  # THROWS:
  #  RuntimeException, etc...
  #
  def initUserStore
    userStoreTransport = Thrift::HTTPClientTransport.new($ENuserStoreUrl)
    userStoreProtocol = Thrift::BinaryProtocol.new(userStoreTransport)
    @userStore = Evernote::EDAM::UserStore::UserStore::Client.new(userStoreProtocol)
    self.checkVersion
    self.authUser
  end

  #
  # === NoteStore初期化
  #  ノートストア関連の初期化を行う
  #
  # PARAM:
  #  ustore :: 認証済みのENUserStore情報
  #
  def initNoteStore
    noteStoreUrl = $ENnoteStoreUrlBase + @user.shardId
    noteStoreTransport = Thrift::HTTPClientTransport.new(noteStoreUrl)
    noteStoreProtocol = Thrift::BinaryProtocol.new(noteStoreTransport)
    @noteStore = Evernote::EDAM::NoteStore::NoteStore::Client.new(noteStoreProtocol)
  end

  #
  # === APIバージョンチェック
  #  Evernote APIのバージョンチェックを行う
  #
  def checkVersion
    verOK = @userStore.checkVersion($ScriptName,
                                    Evernote::EDAM::UserStore::EDAM_VERSION_MAJOR,
                                    Evernote::EDAM::UserStore::EDAM_VERSION_MINOR)
    if !verOK then
      raise "EDAM Version is incompatible."
    end
  end

  #
  # === ユーザ認証
  #  ユーザストアにて$EvernoteUsername/$EvernotePasswordの認証を行う
  # 
  def authUser
    authResult = @userStore.authenticate($EvernoteUsername, $EvernotePassword,
                                         $EvernoteConsumerKey, $EvernoteConsumerSecret)
  rescue Evernote::EDAM::Error::EDAMUserException => ex
    parameter = ex.parameter
    errorText = Evernote::EDAM::Error::EDAMErrorCode::VALUE_MAP[ex.errorCode]
    raise "Authentication Failed: #{errorText}(#{parameter})"
  else
    @user = authResult.user
    @token = authResult.authenticationToken
  end

  #
  # === ノートブック情報取得
  #  ノートストアから指定したノートブックの情報を取得
  # PARAM:
  #  notename :: 取得するノートブック名
  # RETVAL:
  #  Evernote::EDAM::Type::Notebook :: 取得したノートブック情報
  #  nil                            :: 取得失敗
  #
  def selectNotebook (notename)
    @notebooks = @noteStore.listNotebooks(@token) if @notebooks.nil?
    @notebooks.each { |nb|
      if nb.name == notename then
        return nb
      end
    }
    return nil
  end

  #
  # === タグ情報取得
  #  ノートストアから指定したタグの情報を取得
  # PARAM:
  #  tagname :: 取得するタグ名
  # RETVAL:
  #  Evernote::EDAM::Type::Tag :: 取得したタグ情報
  #  nil                       :: 取得失敗
  #
  def selectTag (tagname)
    @tags = @noteStore.listTags(@token) if @tags.nil?
    @tags.each { |tg|
      if tg.name == tagname then
        return tg
      end
    }
    return nil
  end

  #
  # === ノート生成
  #  ノートストアに新規ノートを生成する
  # PARAM:
  #  ennote :: 生成するノート情報を保持するENNote情報
  #
  def createNote (ennote)
    @noteStore.createNote(@token, ennote.getNote)
  end

  protected :initUserStore, :initNoteStore, :checkVersion, :authUser
end


#
# == Evernote Note
#  ノート情報に関する処理を行う
# SAMPLE:
#  note = ENNote.new
#  note.setTitle('title')
#  note.setDate(Time.new, Time.now)
#  note.setLocation(35.686533327621, 139.69192653894, 0)
#  note.setNotebook(edam.selectNotebook('notename'))
#  note.setTag(edam.selectTag('tagname'))
#  note.setResource(ENResource.new)
#  edam.createNote(note.getNote)
#
class ENNote

  #
  # === 初期化処理
  #
  def initialize
    @note = Evernote::EDAM::Type::Note.new
    @content = ''
  end

  #
  # === タイトル設定
  #  ノートのタイトルを設定する
  # PARAM:
  #  title :: タイトル文字列
  #
  def setTitle (title)
    @note.title = title
  end

  #
  # === 時刻情報設定
  #  作成／更新時刻の設定を行う
  # PARAM:
  #  created :: 作成日時
  #  updated :: 更新日時
  #
  def setDate (created, updated)
    @note.created = created.to_i * 1000 unless created.nil?
    @note.updated = updated.to_i * 1000 unless updated.nil?
  end

  #
  # === 位置情報設定
  #  位置情報の設定を行う
  # PARAM:
  #  latitude  :: 緯度情報
  #  longigude :: 経度情報
  #  altitude  :: 標高情報
  #
  def setLocation (latitude, longitude, altitude)
    na = Evernote::EDAM::Type::NoteAttributes.new()
    na.latitude = latitude
    na.longitude = longitude
    na.altitude = altitude
    @note.attributes = na
  end

  #
  # === Notebook設定
  #  Notebook情報の設定を行う
  # NOTE:
  #  未設定の場合はデフォルトNotebookに保存される
  # PARAM:
  #  notebook :: 設定するノートブック情報
  #
  def setNotebook (notebook)
    @note.notebookGuid = notebook.guid
  end

  #
  # === タグ設定
  #  タグ情報の設定を行う
  # PARAM:
  #  tag :: 設定するタグ情報
  #
  def setTags (tag)
    @note.tagGuids = Array.new if @note.tagGuids.nil?
    @note.tagGuids << tag.guid
  end

  #
  # === リソース情報設定
  #  画像などのリソース情報を設定する
  # PARAM:
  #  enrsc :: 設定するリソース情報のENResource
  #
  def setResource (enrsc)
    @note.resources = Array.new if @note.resources.nil?
    @note.resources << enrsc.getResource
    @content << enrsc.getContent
  end

  #
  # === ノートの取得
  #  設定した情報を正規化(てかXMLの調整)してノート情報を返す
  # RETVAL:
  #  Evernote::EDAM::Type::Note :: ノート情報
  #
  def getNote
    if @note.content.nil? then
      @note.content = '<?xml version="1.0" encoding="UTF-8"?>' +
        '<!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml2.dtd">' +
        '<en-note>' + @content + '</en-note>'
    end
    return @note
  end
end


#
# == Evernote Note Resource Module
#  ノートのリソース情報モジュール
#
# USAGE:
#  getContent  :: encContentを実行(あれば)して@contentを返す
#  getResource :: encResourceを実行(あれば)して@resourceを返す
#
module ENResource
  #
  # === リソース情報Content取得
  #
  # RETVAL:
  #  String
  #
  def getContent
    self.encContent if defined? self.encContent
    return @content
  end

  #
  # === リソース情報取得
  #
  # RETVAL:
  #  Evernote::EDAM::Type::Resource
  #
  def getResource
    self.encResource if defined? self.encResource
    return @resource
  end
end


#
# == Evernote Note Resource(Image)
#  ノートの画像リソース情報に関する処理を行う
# SAMPLE:
#  imgrsc = ENImageResource('filename', 'image/jpeg', File.basename('filename'))
#  p imgrsc.getContent  #=> '<en-media type="image/jpeg" hash-"xxxx"/><br/>'
#  p imgrsc.getResource #=> Evernote::EDAM::Type::Resource
#
class ENImageResource
  include ENResource

  #
  # === 初期化処理
  #
  def initialize (filename, mimetype, basename)
    data = Evernote::EDAM::Type::Data.new
    image = File.open(filename, "rb") { |io| io.read }

    @mime = mimetype
    @hash = Digest::MD5.new.hexdigest(image)
    data.size = image.size
    data.bodyHash = @hash
    data.body = image
    
    @resource = Evernote::EDAM::Type::Resource.new
    @resource.mime = @mime
    @resource.data = data
    @resource.attributes = Evernote::EDAM::Type::ResourceAttributes.new
    @resource.attributes.fileName = basename
  end

  #
  # === ノートのContent情報を整形
  #  自分の持っているリソースの<en-media>タグ情報を生成する
  #
  def encContent
    @content = '<en-media type="' + @mime + '" hash="' + @hash + '"/><br/>'
  end
end


#
# == ファイル情報
#  検索して取得したローカルファイルの各種情報を保持する
# SAMPLE:
#  e = FileEntry.new(filename)
#  e.show
#  e.toNote(ENNote.new)
#
class FileEntry

  #
  # === 初期化処理
  #  与えられたファイル名を元にファイル情報を収集して情報を格納する
  # PARAM:
  #  name :: ファイル名
  #
  def initialize (name)
    @filename = name

    # ファイル名を元にファイル情報を取得して格納する
    s = File.stat(@filename)
    @created = s.ctime
    @updated = s.mtime

    # その他の情報も適当に取得しておく
    @mimetype = MIME::Types.type_for(@filename).to_s
    @basename = File.basename(@filename)

    # JPEGだったらEXIF関連情報収集
    if @mimetype == "image/jpeg" then
      self.getExif
    end
  end

  #
  # === 情報表示(DBG)
  #  自分が保持する情報を表示する
  #
  def show
    puts "#{@filename} (#{@basename})"
    puts "  #{@mimetype} | #{@created} | #{@updated}"
    if !@latitude.nil? then
      puts "  #{@latitude.to_f} | #{@longitude.to_f} | #{@attitude.to_f}"
    end
  end

  #
  # === ENNote情報設定
  #  ENNoteに情報を設定する
  # PARAM:
  #  ennote :: 設定するENNote情報
  #
  def toNote (ennote)
    rsc = ENImageResource.new(@filename, @mimetype, @basename)

    ennote.setTitle(@created.strftime($NoteTitleFormat))
    ennote.setDate(@created, @updated)
    ennote.setLocation(@latitude, @longitude, @attitude) unless @latitude.nil?
    ennote.setResource(rsc)
    return ennote
  end

  #
  # === JPEGのEXIF情報取得
  #  JPEGファイルからEXIF情報を取得して情報を格納する
  #
  def getExif
    e = EXIFR::JPEG.new(@filename).exif
    unless e.nil? then
      self.getExifComm(e)
      self.getExifGps(e)
    end
  end

  #
  # === EXIF:一般情報取得
  #  時刻などのEXIF情報を取得して情報を更新する
  # PARAM:
  #  exif :: EXIF情報配列
  #
  def getExifComm (exif)
    # 撮影日時を取得してファイル作成時刻を上書き
    date_time_original = exif[:date_time_original]
    unless date_time_original.nil? then
      @created = date_time_original
    end
    # 最終更新(?)時刻を取得してファイル更新時刻を上書き
    date_time = exif[:date_time]
    unless date_time.nil? then
      @updated = date_time
    end
  end

  #
  # === DMS形式変換
  #  GPS関連の情報をDMS形式から数値に変換
  # PARAM:
  #  negate :: trueなら計算結果を反転する
  #  d :: DMS形式:D
  #  m :: DMS形式:M
  #  s :: DMS形式:S
  # RETVAL:
  #  GPS緯度・経度情報数値
  #
  def dms2d(negate, d, m, s)
    ddd = d + m/60 + s/3600
    return negate ? -ddd : ddd
  end

  #
  # === EXIF:GPS関連情報取得
  #  GPS関連のEXIF情報を取得して情報を格納する
  # PARAM:
  #  exif :: EXIF情報配列
  #
  def getExifGps (exif)

    # GPS緯度情報を取得
    lat = exif[:gps_latitude]
    latR = exif[:gps_latitude_ref]
    unless lat.nil? or latR.nil? then
      @latitude = dms2d(latR != "N", lat[0], lat[1], lat[2])
    end

    # GPS経度情報を取得
    lng = exif[:gps_longitude]
    lngR = exif[:gps_longitude_ref]
    unless lng.nil? or lngR.nil? then
      @longitude = dms2d(lngR != "E", lng[0], lng[1], lng[2])
    end

    # GPS標高情報を取得
    @altitude = exif[:gps_altitude]
  end

  protected :getExif, :dms2d, :getExifComm, :getExifGps
  attr_reader :filename, :mimetype, :basename
end



#
# === Growlエラー表示
#  growlnotifyでエラー通知を表示する
# MEMO:
#  Meow使えるともっと良いのかもしれないけど開発環境で動かないの…orz
#
def notify (stickie, title, message)
  sflag = "-s" if stickie
  io = IO.popen("/usr/local/bin/growlnotify #{sflag} '#{title}'", "r+")
  io.puts message
  io.close_write
end


#
# - MAIN -
#
if ARGV.size < 1 then
  notify(true, "Error:#{$ScriptName}", "Usage error: File not specified.")
  exit(1)
end
begin
  edam = EdamApiMng.new
  notebook = edam.selectNotebook($ENStoreNotebookName) unless $ENStoreNotebookName.nil?
  unless $ENStoreTagName.nil? then
    tags = Array.new
    $ENStoreTagName.each { |tag|
      tags << edam.selectTag(tag)
    }
  end

  ARGV.each { |fname|
    entry = FileEntry.new(fname)
#    entry.show

    note = ENNote.new
    note.setNotebook(notebook) unless notebook.nil?
    tags.each { |tag|
      note.setTags(tag)
    } unless tags.nil?
    entry.toNote(note)
    edam.createNote(note)

    notify(false, $ScriptName, "#{entry.basename} is Added to Evernote.") if $NotifySuccessed
    File.delete(fname) if $RemoveFileSuccessed
  }
rescue => e
  notify(true, "Error:#{$ScriptName}", e.to_s)
end
