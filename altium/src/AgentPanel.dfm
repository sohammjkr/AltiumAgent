object AgentForm: TAgentForm
  Left = 240
  Top = 140
  BorderStyle = bsSizeable
  Caption = 'Altium Agent'
  ClientHeight = 640
  ClientWidth = 460
  Color = clBtnFace
  Constraints.MinHeight = 400
  Constraints.MinWidth = 340
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -11
  Font.Name = 'Segoe UI'
  Font.Style = []
  OldCreateOrder = False
  Position = poScreenCenter
  OnClose = FormClose
  OnCreate = FormCreate
  PixelsPerInch = 96
  TextHeight = 13
  object StatusLabel: TLabel
    Left = 10
    Top = 614
    Width = 440
    Height = 15
    Anchors = [akLeft, akRight, akBottom]
    AutoSize = False
    Caption = 'Ready'
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clGrayText
    Font.Height = -11
    Font.Name = 'Segoe UI'
    Font.Style = []
    ParentFont = False
  end
  object TranscriptMemo: TMemo
    Left = 10
    Top = 10
    Width = 440
    Height = 468
    Anchors = [akLeft, akTop, akRight, akBottom]
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -11
    Font.Name = 'Consolas'
    Font.Style = []
    ParentFont = False
    ReadOnly = True
    ScrollBars = ssVertical
    TabOrder = 0
    WordWrap = True
  end
  object InputMemo: TMemo
    Left = 10
    Top = 488
    Width = 440
    Height = 84
    Anchors = [akLeft, akRight, akBottom]
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -11
    Font.Name = 'Segoe UI'
    Font.Style = []
    ParentFont = False
    ScrollBars = ssVertical
    TabOrder = 1
    WordWrap = True
    OnKeyDown = InputMemoKeyDown
  end
  object SendButton: TButton
    Left = 342
    Top = 580
    Width = 108
    Height = 28
    Anchors = [akRight, akBottom]
    Caption = 'Send  (Ctrl+Enter)'
    Default = True
    TabOrder = 2
    OnClick = SendButtonClick
  end
  object StopButton: TButton
    Left = 262
    Top = 580
    Width = 74
    Height = 28
    Anchors = [akRight, akBottom]
    Caption = 'Stop'
    TabOrder = 3
    OnClick = StopButtonClick
  end
end
