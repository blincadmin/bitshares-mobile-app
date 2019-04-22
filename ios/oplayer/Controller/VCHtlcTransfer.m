//
//  VCHtlcTransfer.m
//  oplayer
//
//  Created by SYALON on 13-10-23.
//
//

#import "VCHtlcTransfer.h"
#import "BitsharesClientManager.h"

#import "VCSearchNetwork.h"
#import "VCTransactionConfirm.h"

#import "MBProgressHUD.h"
#import "OrgUtils.h"
#import "NativeAppDelegate.h"
#import "UIDevice+Helper.h"
#import "MyNavigationController.h"
#import "AppCacheManager.h"
#import "ViewTextFieldOwner.h"
#import "WalletManager.h"

enum
{
    kVcFormArgs = 0,
    kVcSubmitBtn,
    
    kVcMax
};

enum
{
    kVcSubFrom = 0,                 //  来自
    kVcSubTo,                       //  发往
    kVcSubAssetID,                  //  转账资产
    
    kVcSubAssetAmountValue,         //  转账数量输入框
    kVcSubAssetAmountAvailable,     //  转账数量可用余额
    
    kVcSubEmpty,                    //  空行
    
    //  Pre-Image mode
    kVcSubPreimage_Preimage,        //  原像
    kVcSubPreimage_AdvSwitch,       //  高级设置
    kVcSubPreimage_HashMethod,      //  Hash算法
    kVcSubPreimage_Expiration,      //  合约有效期
    
    //  Hash-Code mode
    kVcSubHashCode_HashCode,        //  Hash值(部署码)
    kVcSubHashCode_PreimageLength,  //  原像长度
    kVcSubHashCode_HashMethod,      //  Hash算法
    kVcSubHashCode_Expiration,      //  合约有效期
};

@interface VCHtlcTransfer ()
{
    EHtlcDeployMode         _mode;
    BOOL                    _havePreimage;
    NSMutableArray*         _rowTypeArray;
    
    NSDictionary*           _default_asset;     //  默认转账资产
    NSDictionary*           _full_account_data; //  数据 - 帐号全数据（包含帐号、资产、挂单、债仓等所有信息）
    NSArray*                _asset_list;        //  数据 - 用户不为0的所有资产列表
    NSMutableDictionary*    _balances_hash;     //  数据 - 资产ID和对应的余额信息Hash。
    NSDictionary*           _fee_item;          //  手续费对象
    
    UITableViewBase*        _mainTableView;
    UITableViewCellBase*    _cellAssetAvailable;
    
    MyTextField*            _tf_amount;
    MyTextField*            _tf_preimage_or_hash;
    
    ViewBlockLabel*         _goto_submit;       //  创建合约
    
    NSMutableDictionary*    _transfer_args;
    NSDecimalNumber*        _n_available;
    
    BOOL                    _enable_more_args;  //  启用高级设置
    
    NSArray*                _const_hashtype_list;
    NSArray*                _const_expire_list;
    
    NSDictionary*           _currHashType;
    NSDictionary*           _currExpire;
    NSInteger               _currPreimageLength;
}

@end

@implementation VCHtlcTransfer

-(void)dealloc
{
    _fee_item = nil;
    _asset_list = nil;
    _full_account_data = nil;
    _balances_hash = nil;

    if (_tf_amount){
        _tf_amount.delegate = nil;
        _tf_amount = nil;
    }

    if (_tf_preimage_or_hash){
        _tf_preimage_or_hash.delegate = nil;
        _tf_preimage_or_hash = nil;
    }
    
    _transfer_args = nil;
    _n_available = nil;
    _cellAssetAvailable = nil;
    if (_mainTableView){
        [[IntervalManager sharedIntervalManager] releaseLock:_mainTableView];
        _mainTableView.delegate = nil;
        _mainTableView = nil;
    }
}

- (void)_buildRowTypeArray
{
    [_rowTypeArray removeAllObjects];
    
    //  base rows
    [_rowTypeArray addObject:@(kVcSubFrom)];
    [_rowTypeArray addObject:@(kVcSubTo)];
    [_rowTypeArray addObject:@(kVcSubAssetID)];
    [_rowTypeArray addObject:@(kVcSubAssetAmountValue)];
    [_rowTypeArray addObject:@(kVcSubAssetAmountAvailable)];
    [_rowTypeArray addObject:@(kVcSubEmpty)];
    
    if (_mode == EDM_PREIMAGE){
        //  preimage mode
        [_rowTypeArray addObject:@(kVcSubPreimage_Preimage)];
        [_rowTypeArray addObject:@(kVcSubPreimage_AdvSwitch)];
        if (_enable_more_args){
            [_rowTypeArray addObject:@(kVcSubPreimage_HashMethod)];
            [_rowTypeArray addObject:@(kVcSubPreimage_Expiration)];
        }
    }else{
        //  hashcode mode
        [_rowTypeArray addObject:@(kVcSubHashCode_HashCode)];
        [_rowTypeArray addObject:@(kVcSubHashCode_PreimageLength)];
        [_rowTypeArray addObject:@(kVcSubHashCode_HashMethod)];
        [_rowTypeArray addObject:@(kVcSubHashCode_Expiration)];
    }
}

- (id)initWithUserFullInfo:(NSDictionary*)full_account_data mode:(EHtlcDeployMode)mode havePreimage:(BOOL)havePreimage
{
    self = [super init];
    if (self) {
        // Custom initialization
        _mode = mode;
        _havePreimage = havePreimage;
        _rowTypeArray = [NSMutableArray array];
        _default_asset = nil;//TODO:2.1无用？
        _full_account_data = full_account_data;
        _transfer_args = nil;
        _balances_hash = nil;
        _fee_item = nil;
        _asset_list = nil;
        _enable_more_args = NO;
        
        _const_hashtype_list = @[
                                 @{@"name":@"RIPEMD160", @"value":@0},
                                 @{@"name":@"SHA1", @"value":@1},
                                 @{@"name":@"SHA256", @"value":@2}
                                 ];
        _currHashType = [_const_hashtype_list lastObject];
        
        //  TODO:fowallet 最大时间不能超过理事会 parameters.extensions.value.updatable_htlc_options; 配置。
        if (_mode == EDM_PREIMAGE || _havePreimage){
            //  主动创建时候的合约有效期（先创建）
            _const_expire_list = @[
                                   @{@"name":@"3天", @"value":@(3600*24*3)},
                                   @{@"name":@"5天", @"value":@(3600*24*5)},
                                   @{@"name":@"7天", @"value":@(3600*24*7)},
                                   @{@"name":@"15天", @"value":@(3600*24*15)},
                                   ];
            _currExpire = [_const_expire_list objectAtIndex:1];
        }else{
            //  被动创建时候的合约有效期（后创建）
            _const_expire_list = @[
                                   @{@"name":@"6小时", @"value":@(3600*6)},
                                   @{@"name":@"12小时", @"value":@(3600*12)},
                                   @{@"name":@"1天", @"value":@(3600*24*1)},
                                   @{@"name":@"2天", @"value":@(3600*24*2)},
                                   @{@"name":@"3天", @"value":@(3600*24*3)},
                                   ];
            _currExpire = [_const_expire_list objectAtIndex:2];
        }
        
        _currPreimageLength = [self _randomSecurePreimage].length;

        [self _buildRowTypeArray];
    }
    return self;
}

/**
 *  随机生成安全的原像
 */
- (NSString*)_randomSecurePreimage
{
    //  TODO:fowallet 最大原像不能超过 o.preimage_size <= htlc_options->max_preimage_size
    return [[NSString stringWithFormat:@"BTSPP%@PREIMAGE", [WalletManager randomPrivateKeyWIF]] uppercaseString];
}

/**
 *  (private) 根据帐号fulldata信息初始化转账相关参数。
 */
- (void)genTransferDefaultArgs:(id)full_account_data
{
    //  保存当前帐号信息
    if (full_account_data){
        _full_account_data = full_account_data;
    }
    
    ChainObjectManager* chainMgr = [ChainObjectManager sharedChainObjectManager];
    
    //  初始化余额Hash(原来的是Array)
    _balances_hash = [NSMutableDictionary dictionary];
    for (id balance_object in [_full_account_data objectForKey:@"balances"]) {
        id asset_type = [balance_object objectForKey:@"asset_type"];
        id balance = [balance_object objectForKey:@"balance"];
        [_balances_hash setObject:@{@"asset_id":asset_type, @"amount":balance} forKey:asset_type];
    }
    id balances_list = [_balances_hash allValues];
    
    //  计算手续费对象（更新手续费资产的可用余额，即减去手续费需要的amount）
    _fee_item = [chainMgr estimateFeeObject:ebo_htlc_create balances:balances_list];
    id fee_asset_id = _fee_item[@"fee_asset_id"];
    id fee_balance = [_balances_hash objectForKey:fee_asset_id];
    if (fee_balance){
        unsigned long long fee = [[_fee_item objectForKey:@"amount"] unsignedLongLongValue];
        unsigned long long old = [[fee_balance objectForKey:@"amount"] unsignedLongLongValue];
        id new_balance;
        if (old >= fee){
            new_balance = @{@"asset_id":fee_asset_id, @"amount":@(old - fee)};
        }else{
            new_balance = @{@"asset_id":fee_asset_id, @"amount":@0};
        }
        [_balances_hash setObject:new_balance forKey:fee_asset_id];
    }
    
    //  获取余额不为0的资产列表
    id none_zero_balances = [balances_list ruby_select:(^BOOL(id balance_item) {
        return [[balance_item objectForKey:@"amount"] unsignedLongLongValue] != 0;
    })];
    
    //  如果资产列表为空，则添加默认值。{BTS:0}
    if ([none_zero_balances count] <= 0){
        id balance_object = @{@"asset_id":chainMgr.grapheneCoreAssetID, @"amount":@0};
        none_zero_balances = @[balance_object];
        [_balances_hash setObject:balance_object forKey:[balance_object objectForKey:@"asset_id"]];
    }
    
    //  获取资产详细信息列表
    _asset_list = [none_zero_balances ruby_map:(^id(id balance_item) {
        return [chainMgr getChainObjectByID:[balance_item objectForKey:@"asset_id"]];
    })];
    assert([_asset_list count] > 0);
    
    //  初始化转账默认参数：from、fee_asset
    id last_asset = nil;
    if (_transfer_args){
        //  REMARK：第二次调用该方法时才存在 last_asset，上次转账的资产。
        last_asset = [_transfer_args objectForKey:@"asset"];
    }
    _transfer_args = [NSMutableDictionary dictionary];
    id account_info = [_full_account_data objectForKey:@"account"];
    [_transfer_args setObject:@{@"id":account_info[@"id"], @"name":account_info[@"name"]} forKey:@"from"];
    if (!_default_asset){
        //  TODO:fowallet 默认值，优先选择CNY、没CNY选择BTS。TODO：USD呢？？
        _default_asset = [_asset_list ruby_find:(^BOOL(id src) {
            return [[src objectForKey:@"id"] isEqualToString:@"1.3.113"];
        })];
        if (!_default_asset){
            _default_asset = [_asset_list ruby_find:(^BOOL(id src) {
                return [[src objectForKey:@"id"] isEqualToString:@"1.3.0"];
            })];
        }
        if (!_default_asset){
            _default_asset = [_asset_list firstObject];
        }
    }
    id fee_asset = [[ChainObjectManager sharedChainObjectManager] getChainObjectByID:[_fee_item objectForKey:@"fee_asset_id"]];
    [_transfer_args setObject:fee_asset forKey:@"fee_asset"];
    
    //  设置当前资产
    [self setAsset:last_asset ? : _default_asset];
}

/**
 *  (private) 转账成功后刷新界面。
 */
- (void)refreshUI:(id)new_full_account_data
{
    _tf_amount.text = @"";
    _tf_preimage_or_hash.text = @"";
    [self genTransferDefaultArgs:new_full_account_data];
    [_mainTableView reloadData];
}

- (void)resignAllFirstResponder
{
    //  REMARK：强制结束键盘
    [self.view endEditing:YES];
    [_tf_amount safeResignFirstResponder];
    [_tf_preimage_or_hash safeResignFirstResponder];
}

- (void)onAmountAllButtonClicked:(UIButton*)sender
{
    _tf_amount.text = [NSString stringWithFormat:@"%@", _n_available];
    [self onAmountChanged];
}

/**
 *  复制 or 粘贴按钮点击
 */
- (void)onCopyOrPasteButtonClicked:(UIButton*)sender
{
    if (_mode == EDM_PREIMAGE){
        //  copy
        //  TODO:2.1多语言
        id preimage = _tf_preimage_or_hash.text ?: @"";
        [UIPasteboard generalPasteboard].string = preimage;
        [OrgUtils makeToast:[NSString stringWithFormat:@"原像已复制：%@", preimage]];
    }else{
        //  paste
        NSString* hashcode = [UIPasteboard generalPasteboard].string ?: @"";
        //  TODO:检测是否是有效的Hashcode格式。
        _tf_preimage_or_hash.text = hashcode;
    }
}

- (void)viewDidLoad
{
    [super viewDidLoad];
	// Do any additional setup after loading the view.
    
    //  背景颜色
    self.view.backgroundColor = [ThemeManager sharedThemeManager].appBackColor;
    
    //  初始化UI TODO:2.1多语言
    NSString* placeHolderAmount = NSLocalizedString(@"kVcTransferTipInputSendAmount", @"请输入转账金额");
    NSString* placeHolderMemo = _mode == EDM_PREIMAGE ? NSLocalizedString(@"kVcHtlcPlaceholderInputPreimage", @"请输入合约的原像") : NSLocalizedString(@"kVcHtlcPlaceholderInputPreimageHash", @"请输入原像的哈希值");
    CGRect rect = [self makeTextFieldRect];
    _tf_amount = [self createTfWithRect:[self makeTextFieldRectFull] keyboard:UIKeyboardTypeDecimalPad placeholder:placeHolderAmount];
    _tf_preimage_or_hash = [self createTfWithRect:rect keyboard:UIKeyboardTypeDefault placeholder:placeHolderMemo];
    _tf_amount.showBottomLine = YES;
    
    //  设置属性颜色等
    _tf_preimage_or_hash.updateClearButtonTintColor = YES;
    _tf_preimage_or_hash.textColor = [ThemeManager sharedThemeManager].textColorMain;
    _tf_preimage_or_hash.attributedPlaceholder = [[NSAttributedString alloc] initWithString:placeHolderMemo
                                                                                 attributes:@{NSForegroundColorAttributeName:[ThemeManager sharedThemeManager].textColorGray,
                                                                                              NSFontAttributeName:[UIFont systemFontOfSize:17]}];
    _tf_amount.updateClearButtonTintColor = YES;
    _tf_amount.textColor = [ThemeManager sharedThemeManager].textColorMain;
    _tf_amount.attributedPlaceholder = [[NSAttributedString alloc] initWithString:placeHolderAmount
                                                                       attributes:@{NSForegroundColorAttributeName:[ThemeManager sharedThemeManager].textColorGray,
                                                                                    NSFontAttributeName:[UIFont systemFontOfSize:17]}];
    
    //  绑定输入事件（限制输入）
    [_tf_amount addTarget:self action:@selector(onTextFieldDidChange:) forControlEvents:UIControlEventEditingChanged];
    
    //  UI - 转账数量尾部辅助按钮
    UIButton* btn100 = [UIButton buttonWithType:UIButtonTypeSystem];
    btn100.titleLabel.font = [UIFont systemFontOfSize:13];
    [btn100 setTitle:NSLocalizedString(@"kLabelSendAll", @"全部") forState:UIControlStateNormal];
    [btn100 setTitleColor:[ThemeManager sharedThemeManager].textColorHighlight forState:UIControlStateNormal];
    btn100.userInteractionEnabled = YES;
    [btn100 addTarget:self action:@selector(onAmountAllButtonClicked:) forControlEvents:UIControlEventTouchUpInside];
    btn100.frame = CGRectMake(6, 2, 40, 27);
    
    _tf_amount.rightView = btn100;
    _tf_amount.rightViewMode = UITextFieldViewModeAlways;
    
    //  UI - 末尾按钮
    UIButton* btn_copy = [UIButton buttonWithType:UIButtonTypeSystem];
    btn_copy.titleLabel.font = [UIFont systemFontOfSize:13];
    if (_mode == EDM_PREIMAGE){
        [btn_copy setTitle:NSLocalizedString(@"kVcHtlcTailerBtnCopy", @"复制") forState:UIControlStateNormal];
    }else{
        [btn_copy setTitle:NSLocalizedString(@"kVcHtlcTailerBtnPaste", @"粘贴") forState:UIControlStateNormal];
    }
    [btn_copy setTitleColor:[ThemeManager sharedThemeManager].textColorHighlight forState:UIControlStateNormal];
    btn_copy.userInteractionEnabled = YES;
    [btn_copy addTarget:self action:@selector(onCopyOrPasteButtonClicked:) forControlEvents:UIControlEventTouchUpInside];
    btn_copy.frame = CGRectMake(6, 2, 40, 27);
    _tf_preimage_or_hash.rightView = btn_copy;
    _tf_preimage_or_hash.rightViewMode = UITextFieldViewModeAlways;
    
    //  待转账资产总可用余额
    _cellAssetAvailable = [[UITableViewCellBase alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    _cellAssetAvailable.backgroundColor = [UIColor clearColor];
    _cellAssetAvailable.hideBottomLine = YES;
    _cellAssetAvailable.accessoryType = UITableViewCellAccessoryNone;
    _cellAssetAvailable.selectionStyle = UITableViewCellSelectionStyleNone;
    _cellAssetAvailable.textLabel.text = NSLocalizedString(@"kLableAvailable", @"可用");
    _cellAssetAvailable.textLabel.font = [UIFont systemFontOfSize:13.0f];
    _cellAssetAvailable.textLabel.textColor = [ThemeManager sharedThemeManager].textColorNormal;
    _cellAssetAvailable.detailTextLabel.text = @"";
    _cellAssetAvailable.detailTextLabel.font = [UIFont systemFontOfSize:13.0f];
    _cellAssetAvailable.detailTextLabel.textColor = [ThemeManager sharedThemeManager].textColorMain;
    
    _mainTableView = [[UITableViewBase alloc] initWithFrame:[self rectWithoutNavi] style:UITableViewStyleGrouped];
    _mainTableView.delegate = self;
    _mainTableView.dataSource = self;
    _mainTableView.hideAllLines = YES;
    _mainTableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _mainTableView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:_mainTableView];
    
    //  初始化相关参数
    [self genTransferDefaultArgs:nil];
    if (_mode == EDM_PREIMAGE){
        _tf_preimage_or_hash.text = [self _randomSecurePreimage];
    }
    
    UITapGestureRecognizer* pTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)];
    pTap.cancelsTouchesInView = NO; //  IOS 5.0系列导致按钮没响应
    [self.view addGestureRecognizer:pTap];
    
    //  提交按钮
    _goto_submit = [self createCellLableButton:NSLocalizedString(@"kVcHtlcSubmitBtn01", @"创建")];
}

/**
 *  设置待转账资产：更新可用余额等信息
 */
- (void)setAsset:(NSDictionary*)new_asset
{
    [_transfer_args setObject:new_asset forKey:@"asset"];
    
    id new_asset_id = [new_asset objectForKey:@"id"];
    id balance = [[_balances_hash objectForKey:new_asset_id] objectForKey:@"amount"];
    
    _n_available = [NSDecimalNumber decimalNumberWithMantissa:[balance unsignedLongLongValue]
                                                     exponent:-[[new_asset objectForKey:@"precision"] integerValue]
                                                   isNegative:NO];
    
    //  更新可用余额
    _cellAssetAvailable.detailTextLabel.text = [NSString stringWithFormat:@"%@%@", _n_available, [new_asset objectForKey:@"symbol"]];
    
    //  切换资产清除当前输入的数量
    _tf_amount.text = @"";
}

-(void)onTap:(UITapGestureRecognizer*)pTap
{
    [self resignAllFirstResponder];
}

/**
 *  (private) 根据当前哈希算法获取对应的哈希值字节数。
 */
- (NSInteger)_calcHashValueByteSize
{
    switch ([[_currHashType objectForKey:@"value"] integerValue]) {
        case 0: //  RIPEMD160
            return 20;
        case 1: //  SHA1 SHA160
            return 20;
        case 2: //  SHA256
            return 32;
        default:
            assert(false);
            break;
    }
    return 0;
}

/**
 *  (private) 根据当前哈希算法计算原像哈希值。
 */
- (NSData*)_calcPreimageHashCode:(NSData*)preimage
{
    //    sha256((const unsigned char*)[preimage UTF8String], [preimage length], digest);
    //    id preimage_hash = [[NSData alloc] initWithBytes:digest length:sizeof(digest)];
    
//    NSData* message_data = [memo_string dataUsingEncoding:NSUTF8StringEncoding];
//    size_t message_size = (size_t)[message_data length];
//    const unsigned char* message = (const unsigned char*)[message_data bytes];
//    size_t output_size = __bts_aes256_encrypt_with_checksum_calc_outputsize(message_size);
//    unsigned char output[output_size];
//
    switch ([[_currHashType objectForKey:@"value"] integerValue]) {
        case 0: //  RIPEMD160
        {
            //  TODO:2.1
            unsigned char digest[20] = {0, };
        }
            break;
        case 1: //  SHA1 SHA160
        {
            //  TODO:2.1
            unsigned char digest[20] = {0, };
        }
            break;
        case 2: //  SHA256
        {
            unsigned char digest[32] = {0, };
            sha256((const unsigned char*)[preimage bytes], (const size_t)[preimage length], digest);
            return [[NSData alloc] initWithBytes:digest length:sizeof(digest)];
        }
            break;
        default:
            assert(false);
            break;
    }
    return nil;
}

-(void)gotoCreateHTLC
{
    //  === 转账基本参数有效性检测 ===
    //  TODO:fowallet 不足的时候否直接提示显示？？？
    if (![[_fee_item objectForKey:@"sufficient"] boolValue]){
        [OrgUtils makeToast:NSLocalizedString(@"kTipsTxFeeNotEnough", @"手续费不足，请确保帐号有足额的 BTS/CNY/USD 用于支付网络手续费。")];
        return;
    }
    
    id from = [_transfer_args objectForKey:@"from"];
    assert(from);
    id asset = [_transfer_args objectForKey:@"asset"];
    assert(asset);
    id to = [_transfer_args objectForKey:@"to"];
    if (!to){
        [OrgUtils makeToast:NSLocalizedString(@"kVcTransferSubmitTipSelectTo", @"请选择收款帐号。")];
        return;
    }
    if ([[from objectForKey:@"id"] isEqualToString:[to objectForKey:@"id"]]){
        [OrgUtils makeToast:NSLocalizedString(@"kVcTransferSubmitTipFromToIsSame", @"收款账号和发送账号不能相同。")];
        return;
    }
    
    //  TODO:fowallet to在黑名单中 风险提示。
    
    id str_amount = _tf_amount.text;
    if (!str_amount || [str_amount isEqualToString:@""]){
        [OrgUtils makeToast:NSLocalizedString(@"kVcTransferSubmitTipPleaseInputAmount", @"请输入转账金额")];
        return;
    }
    
    id n_amount = [self auxGetStringDecimalNumberValue:str_amount];
    
    //  <= 0 判断，只有 大于 才为 NSOrderedDescending。
    NSDecimalNumber* n_zero = [NSDecimalNumber zero];
    if ([n_amount compare:n_zero] != NSOrderedDescending){
        [OrgUtils makeToast:NSLocalizedString(@"kVcTransferSubmitTipPleaseInputAmount", @"请输入转账金额")];
        return;
    }
    
    //  _n_available < n_amount
    if ([_n_available compare:n_amount] == NSOrderedAscending){
        [OrgUtils makeToast:NSLocalizedString(@"kVcTransferSubmitTipAmountNotEnough", @"数量不足")];
        return;
    }
    
    //  === 风险提示 ===
    //  TODO:2.1 多语言
    NSData* preimage_hash = nil;
    NSInteger preimage_length = 0;
    
    id message;
    id title = NSLocalizedString(@"kWarmTips", @"温馨提示");
    if (_mode == EDM_PREIMAGE){
        NSString* preimage = [NSString trim:_tf_preimage_or_hash.text];
        if (![OrgUtils isValidHTCLPreimageFormat:preimage]){
            [OrgUtils showMessage:@"原像格式为20位以上，且必须同时包含大写字母和数字。"];
            return;
        }
        
        NSData* preimage_data = [preimage dataUsingEncoding:NSUTF8StringEncoding];
        preimage_hash = [self _calcPreimageHashCode:preimage_data];
        preimage_length = [preimage_data length];
        
        message = @"请确认已经复制备份好【原像】信息，丢失原像只能等待合约到期后自动解锁。是否继续创建合约？";
    }else{
        NSString* hashvalue = [NSString trim:_tf_preimage_or_hash.text];
        if (!hashvalue){
            [OrgUtils makeToast:@"请输入原像哈希值。"];
            return;
        }
        NSData* hashvalue_data = [hashvalue dataUsingEncoding:NSUTF8StringEncoding];
        NSInteger hashvalue_bytesize = [self _calcHashValueByteSize];
        if ([hashvalue_data length] != hashvalue_bytesize * 2){
            [OrgUtils makeToast:@"请输入有效的原像哈希值。"];
            return;
        }
        //  TODO:2.1 是否是有效的16进制 检测
        unsigned char hashvalue_bytes[hashvalue_bytesize];
        hex_decode((const unsigned char*)[hashvalue_data bytes], (const size_t)[hashvalue_data length], hashvalue_bytes);
        preimage_hash = [[NSData alloc] initWithBytes:hashvalue_bytes length:hashvalue_bytesize];
        preimage_length = _currPreimageLength;
        
        if (_havePreimage){
            message = @"主动创建合约请备份好【原像】信息，丢失原像只能等待合约到期后自动解锁。是否继续创建合约？";
        }else{
            message = @"被动部署合约请仔细确认对方已经部署好了相同的合约，并仔细核对各种参数。\n\n※ 注意 ※\n1、原像哈希和原像长度必须和对方完全匹配。\n2、建议合约【有效期】务必“小于”对方合约有效期2天以上，否则可能造成资金损失。是否继续创建合约？";
            title = @"风险提示";
        }
    }
    [[UIAlertViewManager sharedUIAlertViewManager] showCancelConfirm:message
                                                           withTitle:title
                                                          completion:^(NSInteger buttonIndex)
     {
         if (buttonIndex == 1)
         {
             //  --- 参数大部分检测合法 执行请求 ---
             [self GuardWalletUnlocked:NO body:^(BOOL unlocked) {
                 if (unlocked){
                     [self _gotoCreateHTLCCore:from to:to asset:asset amount:n_amount
                                 preimage_hash:preimage_hash preimage_length:preimage_length
                                      hashtype:[[_currHashType objectForKey:@"value"] integerValue]
                          claim_period_seconds:[[_currExpire objectForKey:@"value"] integerValue]];
                 }
             }];
         }
     }];
}

/**
 *  (private) 创建合约核心。
 */
- (void)_gotoCreateHTLCCore:(id)from
                         to:(id)to
                      asset:(id)asset
                     amount:(id)n_amount
              preimage_hash:(id)preimage_hash
            preimage_length:(NSInteger)preimage_length
                   hashtype:(NSInteger)hashtype
       claim_period_seconds:(NSInteger)claim_period_seconds
{
    id n_amount_pow = [NSString stringWithFormat:@"%@", [n_amount decimalNumberByMultiplyingByPowerOf10:[asset[@"precision"] integerValue]]];
    id fee_asset_id = [_fee_item objectForKey:@"fee_asset_id"];
    
    id op = @{
              @"fee":@{
                      @"amount":@0,
                      @"asset_id":fee_asset_id,
                      },
              @"from":from[@"id"],
              @"to":to[@"id"],
              @"amount":@{
                      @"amount":@([n_amount_pow unsignedLongLongValue]),
                      @"asset_id":asset[@"id"],
                      },
              @"preimage_hash":@[@(hashtype), preimage_hash],
              @"preimage_size":@(preimage_length),
              @"claim_period_seconds":@(claim_period_seconds)
              };
    
    //  TODO:2.1 提案？？
    
    id opaccount = [_full_account_data objectForKey:@"account"];
    id opaccount_id = [opaccount objectForKey:@"id"];
    assert(opaccount_id);
    
    //  确保有权限发起普通交易，否则作为提案交易处理。
    [self GuardProposalOrNormalTransaction:ebo_htlc_create
                     using_owner_authority:NO
                  invoke_proposal_callback:NO
                                    opdata:op
                                 opaccount:opaccount
                                      body:^(BOOL isProposal, NSDictionary *proposal_create_args)
     {
         assert(!isProposal);
         //  请求网络广播
         [self showBlockViewWithTitle:NSLocalizedString(@"kTipsBeRequesting", @"请求中...")];
         [[[[BitsharesClientManager sharedBitsharesClientManager] htlcCreate:op] then:(^id(id transaction_confirmation) {
             [self hideBlockView];
             NSLog(@"%@", transaction_confirmation);
             id new_htlc_id = [OrgUtils extractNewObjectID:transaction_confirmation];
             [OrgUtils makeToast:[NSString stringWithFormat:@"new htlc id: %@", new_htlc_id]];
//             [[[[ChainObjectManager sharedChainObjectManager] queryFullAccountInfo:opaccount_id] then:(^id(id full_data) {
//                 NSLog(@"callorder_update & refresh: %@", full_data);
//                 [self hideBlockView];
//                 //  刷新UI
//                 [self refreshUI:YES new_feed_price_data:nil];
//                 [OrgUtils makeToast:NSLocalizedString(@"kDebtTipTxUpdatePositionFullOK", @"债仓调整完毕。")];
//                 //  [统计]
//                 [Answers logCustomEventWithName:@"txCallOrderUpdateFullOK"
//                                customAttributes:@{@"account":funding_account, @"debt_asset":_debtPair.baseAsset[@"symbol"]}];
//                 return nil;
//             })] catch:(^id(id error) {
//                 [self hideBlockView];
//                 [OrgUtils makeToast:NSLocalizedString(@"kDebtTipTxUpdatePositionOK", @"债仓调整完毕，但刷新界面数据失败，请稍后再试。")];
//                 //  [统计]
//                 [Answers logCustomEventWithName:@"txCallOrderUpdateOK"
//                                customAttributes:@{@"account":funding_account, @"debt_asset":_debtPair.baseAsset[@"symbol"]}];
//                 return nil;
//             })];
             return nil;
         })] catch:(^id(id error) {
             [self hideBlockView];
             [OrgUtils makeToast:NSLocalizedString(@"kTipsTxRequestFailed", @"请求失败，请稍后再试。")];
//             //  [统计]
//             [Answers logCustomEventWithName:@"txCallOrderUpdateFailed"
//                            customAttributes:@{@"account":opaccount_id, @"debt_asset":_debtPair.baseAsset[@"symbol"]}];
             return nil;
         })];
     }];
    
    
//    [[[[BitsharesClientManager sharedBitsharesClientManager] htlcCreate:op] then:(^id(id data) {
//        NSLog(@"%@", data);
//        return nil;
//    })] catch:(^id(id error) {
//        NSLog(@"%@", error);
//        return nil;
//    })];
//    return;
}

//
///**
// *  (private) 辅助 - 判断手续费是否足够，足够则返回需要消耗的手续费，不足则返回 nil。
// *  fee_price_item      - 服务器返回的需要手续费值
// *  fee_asset_id        - 当前手续费资产ID
// *  asset               - 正在转账的资产
// *  n_amount            - 正在转账的数量
// */
//- (id)_isFeeSufficient:(id)fee_price_item fee_asset_id:(NSString*)fee_asset_id asset:(id)asset amount:(id)n_amount
//{
//    assert(fee_price_item);
//    assert(fee_asset_id);
//    assert(asset);
//    assert(n_amount);
//    assert([fee_asset_id isEqualToString:[fee_price_item objectForKey:@"asset_id"]]);
//
//    //  1、转账消耗资产值（只有转账资产和手续费资产相同时候才设置）
//    NSDecimalNumber* n_transfer_cost = [NSDecimalNumber zero];
//    if ([asset[@"id"] isEqualToString:fee_asset_id]){
//        n_transfer_cost = n_amount;
//    }
//
//    //  2、手续费消耗值
//    id fee_asset = _transfer_args[@"fee_asset"];
//    assert(fee_asset);
//    NSDecimalNumber* n_fee_cost = [NSDecimalNumber decimalNumberWithMantissa:[[fee_price_item objectForKey:@"amount"] unsignedLongLongValue]
//                                                                    exponent:-[fee_asset[@"precision"] integerValue]
//                                                                  isNegative:NO];
//
//    //  3、总消耗值
//    id n_total_cost = [n_transfer_cost decimalNumberByAdding:n_fee_cost];
//
//    //  4、获取手续费资产总的可用余额
//    id n_available = [NSDecimalNumber zero];
//    for (id balance_object in [_full_account_data objectForKey:@"balances"]) {
//        id asset_type = [balance_object objectForKey:@"asset_type"];
//        if ([asset_type isEqualToString:fee_asset_id]){
//            n_available = [NSDecimalNumber decimalNumberWithMantissa:[balance_object[@"balance"] unsignedLongLongValue]
//                                                            exponent:-[fee_asset[@"precision"] integerValue]
//                                                          isNegative:NO];
//            break;
//        }
//    }
//
//    //  5、判断：n_available < n_total_cost
//    if ([n_available compare:n_total_cost] == NSOrderedAscending){
//        //  不足：返回 nil。
//        return nil;
//    }
//
//    //  足够（返回手续费值）
//    return n_fee_cost;
//}
//
//-(void)_processTransferCore:(id)from
//                         to:(id)to
//                      asset:(id)asset
//                     amount:(id)n_amount
//{
//    //    NSString* preimage = @"s123";
//    //    unsigned char digest[32] = {0, };
//    //    sha256((const unsigned char*)[preimage UTF8String], [preimage length], digest);
//    //    id preimage_hash = [[NSData alloc] initWithBytes:digest length:sizeof(digest)];
//    //
//    //    id account_info = [_full_account_data objectForKey:@"account"];
//    //    id to1 = [_transfer_args objectForKey:@"to"];
//    //    id op = @{
//    //              @"fee":@{
//    //                      @"amount":@0,
//    //                      @"asset_id":@"1.3.0",
//    //                      },
//    //              @"from":account_info[@"id"],
//    //              @"to":to1[@"id"],
//    //              @"amount":@{
//    //                      @"amount":@(1234),
//    //                      @"asset_id":@"1.3.0",
//    //                      },
//    //              @"preimage_hash":@[@2, preimage_hash],
//    //              @"preimage_size":@([preimage length]),
//    //              @"claim_period_seconds":@(3600*10)
//    //              };
//    //
//    //    [[[[BitsharesClientManager sharedBitsharesClientManager] htlcCreate:op] then:(^id(id data) {
//    //        NSLog(@"%@", data);
//    //        return nil;
//    //    })] catch:(^id(id error) {
//    //        NSLog(@"%@", error);
//    //        return nil;
//    //    })];
//    //    return;
//    
//    
////    //  --- 开始构造OP ---
////    id n_amount_pow = [NSString stringWithFormat:@"%@", [n_amount decimalNumberByMultiplyingByPowerOf10:[asset[@"precision"] integerValue]]];
////    id fee_asset_id = [_fee_item objectForKey:@"fee_asset_id"];
////    id op = @{
////              @"fee":@{
////                      @"amount":@0,
////                      @"asset_id":fee_asset_id,
////                      },
////              @"from":from[@"id"],
////              @"to":to[@"id"],
////              @"amount":@{
////                      @"amount":@([n_amount_pow unsignedLongLongValue]),
////                      @"asset_id":asset[@"id"],
////                      },
////              @"memo":memo_object
////              };
////    //  --- 开始评估手续费 ---
////    [[[[BitsharesClientManager sharedBitsharesClientManager] calcOperationFee:ebo_transfer opdata:op] then:(^id(id fee_price_item) {
////        [self hideBlockView];
////        //  判断手续费是否足够。
////        id n_fee_cost = [self _isFeeSufficient:fee_price_item fee_asset_id:fee_asset_id asset:asset amount:n_amount];
////        if (!n_fee_cost){
////            [OrgUtils makeToast:NSLocalizedString(@"kTipsTxFeeNotEnough", @"手续费不足，请确保帐号有足额的 BTS/CNY/USD 用于支付网络手续费。")];
////            return nil;
////        }
////        //  --- 弹框确认转账行为 ---
////        //  弹确认框之前 设置参数
////        [_transfer_args setObject:n_amount forKey:@"kAmount"];
////        [_transfer_args setObject:n_fee_cost forKey:@"kFeeCost"];
////
////        id op_with_fee = [op mutableCopy];
////        [op_with_fee setObject:fee_price_item forKey:@"fee"];
////        [_transfer_args setObject:[op_with_fee copy] forKey:@"kOpData"];            //  传递过去，避免再次构造。
////        if (memo){
////            [_transfer_args setObject:memo forKey:@"kMemo"];
////        }else{
////            [_transfer_args removeObjectForKey:@"kMemo"];
////        }
////        //  确保有权限发起普通交易，否则作为提案交易处理。
////        [self GuardProposalOrNormalTransaction:ebo_transfer
////                         using_owner_authority:NO
////                      invoke_proposal_callback:NO
////                                        opdata:[_transfer_args objectForKey:@"kOpData"]
////                                     opaccount:[_full_account_data objectForKey:@"account"]
////                                          body:^(BOOL isProposal, NSDictionary *proposal_create_args)
////         {
////             assert(!isProposal);
////             // 有权限：转到交易确认界面。
////             VCTransactionConfirm* vc = [[VCTransactionConfirm alloc] initWithTransferArgs:[_transfer_args copy] callback:(^(BOOL isOk) {
////                 if (isOk){
////                     [self _processTransferCore];
////                 }else{
////                     NSLog(@"cancel...");
////                 }
////             })];
////             vc.title = NSLocalizedString(@"kVcTitleConfirmTransaction", @"请确认交易");
////             vc.hidesBottomBarWhenPushed = YES;
////             [self showModelViewController:vc tag:0];
////         }];
////        return nil;
////    })] catch:(^id(id error) {
////        [self hideBlockView];
////        [OrgUtils makeToast:NSLocalizedString(@"tip_network_error", @"网络异常，请稍后再试。")];
////        return nil;
////    })];
////    return nil;
//}
//
///**
// *  (private) 用户确认完毕 最后提交请求。
// */
//- (void)_processTransferCore
//{
//    id asset = [_transfer_args objectForKey:@"asset"];
//    assert(asset);
//    id op_data = [_transfer_args objectForKey:@"kOpData"];
//    assert(op_data);
//    
//    //  请求网络广播
//    [self showBlockViewWithTitle:NSLocalizedString(@"kTipsBeRequesting", @"请求中...")];
//    [[[[BitsharesClientManager sharedBitsharesClientManager] transfer:op_data] then:(^id(id data) {
//        id account_id = [[_full_account_data objectForKey:@"account"] objectForKey:@"id"];
//        [[[[ChainObjectManager sharedChainObjectManager] queryFullAccountInfo:account_id] then:(^id(id full_data) {
//            NSLog(@"transfer & refresh: %@", full_data);
//            [self hideBlockView];
//            [self refreshUI:full_data];
//            [OrgUtils makeToast:NSLocalizedString(@"kVcTransferTipTxTransferFullOK", @"发送成功。")];
//            //  [统计]
//            [Answers logCustomEventWithName:@"txTransferFullOK" customAttributes:@{@"account":account_id, @"asset":asset[@"symbol"]}];
//            return nil;
//        })] catch:(^id(id error) {
//            [self hideBlockView];
//            [OrgUtils makeToast:NSLocalizedString(@"kVcTransferTipTxTransferOK", @"发送成功，但刷新界面数据失败，请稍后再试。")];
//            //  [统计]
//            [Answers logCustomEventWithName:@"txTransferOK" customAttributes:@{@"account":account_id, @"asset":asset[@"symbol"]}];
//            return nil;
//        })];
//        return nil;
//    })] catch:(^id(id error) {
//        [self hideBlockView];
//        [OrgUtils makeToast:NSLocalizedString(@"kTipsTxRequestFailed", @"请求失败，请稍后再试。")];
//        //  [统计]
//        [Answers logCustomEventWithName:@"txTransferFailed" customAttributes:@{@"asset":asset[@"symbol"]}];
//        return nil;
//    })];
//}

#pragma mark- for UITextFieldDelegate

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string
{
    if (textField != _tf_amount){
        return YES;
    }
    
    id asset = [_transfer_args objectForKey:@"asset"];
    assert(asset);
    
    BOOL result = [OrgUtils isValidAmountOrPriceInput:textField.text
                                                range:range
                                           new_string:string
                                            precision:[[asset objectForKey:@"precision"] integerValue]];
    if (!result){
        [textField.text stringByReplacingCharactersInRange:range withString:@""];
    }
    return result;
}

- (void)onTextFieldDidChange:(UITextField*)textField
{
    if (textField != _tf_amount){
        return;
    }
    [self onAmountChanged];
}

/**
 *  (private) 辅助 - 根据字符串获取 NSDecimalNumber 对象，如果字符串以小数点结尾，则默认添加0。
 */
- (NSDecimalNumber*)auxGetStringDecimalNumberValue:(NSString*)str
{
    //  以小数点结尾则在默认添加0。
    if ([str rangeOfString:@"."].location == [str length] - 1){
        str = [NSString stringWithFormat:@"%@0", str];
    }
    return [NSDecimalNumber decimalNumberWithString:str];
}

/**
 *  (private) 转账数量发生变化。
 */
- (void)onAmountChanged
{
    id asset = [_transfer_args objectForKey:@"asset"];
    assert(asset);
    
    id str_amount = _tf_amount.text;
    
    //  无效输入
    if (!str_amount || [str_amount isEqualToString:@""]){
        _cellAssetAvailable.detailTextLabel.text = [NSString stringWithFormat:@"%@%@", _n_available, [asset objectForKey:@"symbol"]];
        _cellAssetAvailable.detailTextLabel.textColor = [ThemeManager sharedThemeManager].textColorMain;
        return;
    }
    
    //  获取输入的数量
    id n_amount = [self auxGetStringDecimalNumberValue:str_amount];
    
    //  _n_available < n_amount
    if ([_n_available compare:n_amount] == NSOrderedAscending){
        //  数量不足
        _cellAssetAvailable.detailTextLabel.text = [NSString stringWithFormat:@"%@%@(%@)", _n_available, [asset objectForKey:@"symbol"], NSLocalizedString(@"kVcTransferTipAmountNotEnough", @"数量不足")];
        _cellAssetAvailable.detailTextLabel.textColor = [ThemeManager sharedThemeManager].tintColor;
    }else{
        _cellAssetAvailable.detailTextLabel.text = [NSString stringWithFormat:@"%@%@", _n_available, [asset objectForKey:@"symbol"]];
        _cellAssetAvailable.detailTextLabel.textColor = [ThemeManager sharedThemeManager].textColorMain;
    }
}

#pragma mark-
#pragma UITextFieldDelegate delegate method

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    if (textField == _tf_amount)
    {
        [_tf_preimage_or_hash becomeFirstResponder];
    }
    else
    {
        [self.view endEditing:YES];
        [_tf_amount safeResignFirstResponder];
        [_tf_preimage_or_hash safeResignFirstResponder];
    }
    return YES;
}

#pragma mark- TableView delegate method

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return kVcMax;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == kVcFormArgs)
        return [_rowTypeArray count];
    else
        return 1;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == kVcFormArgs){
        switch ([[_rowTypeArray objectAtIndex:indexPath.row] integerValue]) {
            case kVcSubAssetAmountValue:
                return 24.0f;           //  可用余额
            case kVcSubEmpty:
                return 8.0f;
            default:
                break;
        }
    }
    return tableView.rowHeight;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == kVcFormArgs){
        //  REMARK：这个属性是ios7之后添加。
        CGFloat left = tableView.separatorInset.left;
        switch ([[_rowTypeArray objectAtIndex:indexPath.row] integerValue]) {
            case kVcSubAssetAmountValue:
            {
                CGRect old_frame = _tf_amount.frame;
                _tf_amount.frame = CGRectMake(0, 0, self.view.bounds.size.width - left * 2, old_frame.size.height);
            }
                break;
            default:
                break;
        }
    }
}

/**
 *  调整Header和Footer高度。REMARK：header和footer VIEW 不能为空，否则高度设置无效。
 */
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    return 10.0f;
}
- (nullable NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return @" ";
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section
{
    return 10.0f;
}
- (nullable NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return @" ";
}

#pragma mark- for switch action
-(void)onSwitchAction:(UISwitch*)pSwitch
{
    _enable_more_args = pSwitch.on;
    
//    //  REMARK：恢复默认值 TODO:设置默认值。
//    _currHashType = [_const_hashtype_list lastObject];
//    _currExpire = [_const_expire_list objectAtIndex:1];
    
    [self _buildRowTypeArray];
    [_mainTableView reloadData];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    switch (indexPath.section) {
        case kVcFormArgs:
        {
            NSInteger row_type = [[_rowTypeArray objectAtIndex:indexPath.row] integerValue];
            //  TODO:fowallet color
            switch (row_type) {
                case kVcSubFrom:
                {
                    UITableViewCellBase* cell = [[UITableViewCellBase alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
                    cell.backgroundColor = [UIColor clearColor];
                    cell.accessoryType = UITableViewCellAccessoryNone;
                    cell.selectionStyle = UITableViewCellSelectionStyleNone;
                    cell.textLabel.text = NSLocalizedString(@"kVcTransferCellFrom", @"来自帐号");
                    cell.textLabel.textColor = [ThemeManager sharedThemeManager].textColorMain;
                    cell.detailTextLabel.text = [[_transfer_args objectForKey:@"from"] objectForKey:@"name"];
                    cell.detailTextLabel.textColor = [ThemeManager sharedThemeManager].textColorMain;
                    cell.hideTopLine = YES;
                    cell.hideBottomLine = YES;
                    return cell;
                }
                    break;
                case kVcSubTo:
                {
                    UITableViewCellBase* cell = [[UITableViewCellBase alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
                    cell.backgroundColor = [UIColor clearColor];
                    cell.textLabel.text = NSLocalizedString(@"kVcTransferCellTo", @"发往帐号");
                    cell.textLabel.textColor = [ThemeManager sharedThemeManager].textColorMain;
                    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                    cell.selectionStyle = UITableViewCellSelectionStyleBlue;
                    cell.hideTopLine = YES;
                    cell.hideBottomLine = YES;
                    
                    NSString* str = [[_transfer_args objectForKey:@"to"] objectForKey:@"name"];
                    if (!str || [str length] == 0){
                        cell.detailTextLabel.textColor = [ThemeManager sharedThemeManager].textColorGray;
                        cell.detailTextLabel.text = NSLocalizedString(@"kVcTransferTipSelectToAccount", @"请选择收款帐号");
                    }else{
                        cell.detailTextLabel.textColor = [ThemeManager sharedThemeManager].buyColor;//TODO:color
                        cell.detailTextLabel.text = str;
                    }
                    
                    return cell;
                }
                    break;
                case kVcSubAssetID:
                {
                    UITableViewCellBase* cell = [[UITableViewCellBase alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
                    cell.backgroundColor = [UIColor clearColor];
                    cell.textLabel.text = NSLocalizedString(@"kVcTransferCellAsset", @"转账资产");
                    cell.textLabel.textColor = [ThemeManager sharedThemeManager].textColorMain;
                    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                    cell.selectionStyle = UITableViewCellSelectionStyleBlue;
                    cell.hideTopLine = YES;
                    cell.hideBottomLine = YES;
                    id asset = [_transfer_args objectForKey:@"asset"];
                    assert(asset);
                    cell.detailTextLabel.textColor = [ThemeManager sharedThemeManager].textColorMain;
                    cell.detailTextLabel.text = [asset objectForKey:@"symbol"];
                    return cell;
                }
                    break;
                case kVcSubAssetAmountAvailable:
                {
                    return _cellAssetAvailable;
                }
                    break;
                case kVcSubAssetAmountValue:
                {
                    UITableViewCellBase* cell = [[UITableViewCellBase alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
                    cell.backgroundColor = [UIColor clearColor];
                    cell.accessoryType = UITableViewCellAccessoryNone;
                    cell.selectionStyle = UITableViewCellSelectionStyleNone;
                    cell.textLabel.text = @" ";
                    cell.textLabel.textColor = [ThemeManager sharedThemeManager].textColorMain;
                    cell.accessoryView = _tf_amount;
                    //                cell.showCustomBottomLine = NO;
                    cell.hideTopLine = YES;
                    cell.hideBottomLine = YES;
                    return cell;
                }
                    break;
                case kVcSubEmpty:
                {
                    UITableViewCellBase* cell = [[UITableViewCellBase alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
                    cell.backgroundColor = [UIColor clearColor];
                    cell.accessoryType = UITableViewCellAccessoryNone;
                    cell.selectionStyle = UITableViewCellSelectionStyleNone;
                    cell.textLabel.text = @" ";
                    cell.textLabel.font = [UIFont systemFontOfSize:13.0f];
                    cell.hideBottomLine = YES;
                    return cell;
                }
                    break;
                    //  pre-image mode
                case kVcSubPreimage_Preimage:
                case kVcSubHashCode_HashCode:
                {
                    UITableViewCellBase* cell = [[UITableViewCellBase alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
                    cell.backgroundColor = [UIColor clearColor];
                    cell.accessoryType = UITableViewCellAccessoryNone;
                    cell.selectionStyle = UITableViewCellSelectionStyleNone;
                    if (row_type == kVcSubPreimage_Preimage){
                        cell.textLabel.text = NSLocalizedString(@"kVcHtlcCellTitlePreimage", @"原像");
                    }else{
                        cell.textLabel.text = NSLocalizedString(@"kVcHtlcCellTitlePreimageHash", @"原像哈希");
                    }
                    cell.textLabel.textColor = [ThemeManager sharedThemeManager].textColorMain;
                    cell.accessoryView = _tf_preimage_or_hash;
                    cell.showCustomBottomLine = YES;
                    cell.hideTopLine = YES;
                    cell.hideBottomLine = YES;
                    return cell;
                }
                    break;
                case kVcSubPreimage_AdvSwitch:
                {
                    UITableViewCellBase* cell = [[UITableViewCellBase alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
                    cell.backgroundColor = [UIColor clearColor];
                    cell.selectionStyle = UITableViewCellSelectionStyleNone;
                    cell.accessoryType = UITableViewCellAccessoryNone;
                    cell.showCustomBottomLine = YES;
                    
                    UISwitch* pSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
                    pSwitch.tintColor = [ThemeManager sharedThemeManager].textColorGray;        //  边框颜色
                    pSwitch.thumbTintColor = [ThemeManager sharedThemeManager].textColorGray;   //  按钮颜色
                    pSwitch.onTintColor = [ThemeManager sharedThemeManager].textColorHighlight; //  开启时颜色
                    
                    pSwitch.tag = [[_rowTypeArray objectAtIndex:indexPath.row] integerValue];
                    pSwitch.on = _enable_more_args;
                    [pSwitch addTarget:self action:@selector(onSwitchAction:) forControlEvents:UIControlEventValueChanged];
                    cell.accessoryView = pSwitch;
                    
                    cell.textLabel.text = NSLocalizedString(@"kVcHtlcCellTitleAdvSwitch", @"高级设置");
                    return cell;
                }
                    break;
                case kVcSubPreimage_Expiration:
                case kVcSubHashCode_Expiration:
                {
                    //  TODO:2.1多语言
                    UITableViewCellBase* cell = [[UITableViewCellBase alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
                    cell.backgroundColor = [UIColor clearColor];
                    cell.showCustomBottomLine = YES;
                    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                    cell.selectionStyle = UITableViewCellSelectionStyleBlue;
                    cell.textLabel.text = NSLocalizedString(@"kVcHtlcCellTitleClaimPeriod", @"有效期");
                    cell.textLabel.textColor = [ThemeManager sharedThemeManager].textColorMain;
                    cell.detailTextLabel.text = _currExpire[@"name"];
                    cell.detailTextLabel.textColor = [ThemeManager sharedThemeManager].textColorNormal;
                    return cell;
                }
                    break;
                case kVcSubPreimage_HashMethod:
                case kVcSubHashCode_HashMethod:
                {
                    //  TODO:2.1多语言
                    UITableViewCellBase* cell = [[UITableViewCellBase alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
                    cell.backgroundColor = [UIColor clearColor];
                    cell.showCustomBottomLine = YES;
                    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                    cell.selectionStyle = UITableViewCellSelectionStyleBlue;
                    cell.textLabel.text = NSLocalizedString(@"kVcHtlcCellTitleHashMethod", @"哈希算法");
                    cell.textLabel.textColor = [ThemeManager sharedThemeManager].textColorMain;
                    cell.detailTextLabel.text = _currHashType[@"name"];
                    cell.detailTextLabel.textColor = [ThemeManager sharedThemeManager].textColorNormal;
                    return cell;
                }
                    break;
                case kVcSubHashCode_PreimageLength:
                {
                    //  TODO:2.1多语言
                    UITableViewCellBase* cell = [[UITableViewCellBase alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
                    cell.backgroundColor = [UIColor clearColor];
                    cell.showCustomBottomLine = YES;
                    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                    cell.selectionStyle = UITableViewCellSelectionStyleBlue;
                    cell.textLabel.text = NSLocalizedString(@"kVcHtlcCellTitlePreimageLength", @"原像长度");
                    cell.textLabel.textColor = [ThemeManager sharedThemeManager].textColorMain;
                    if (_currPreimageLength > 0){
                        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@", @(_currPreimageLength)];
                        cell.detailTextLabel.textColor = [ThemeManager sharedThemeManager].textColorNormal;
                    }else{
                        cell.detailTextLabel.text = @"请选择原像长度值";
                        cell.detailTextLabel.textColor = [ThemeManager sharedThemeManager].textColorGray;
                    }
                    return cell;
                }
                    break;
                default:
                    break;
            }
        }
            break;
        case kVcSubmitBtn:
        {
            UITableViewCellBase* cell = [[UITableViewCellBase alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            cell.hideBottomLine = YES;
            cell.hideTopLine = YES;
            cell.backgroundColor = [UIColor clearColor];
            [self addLabelButtonToCell:_goto_submit cell:cell leftEdge:tableView.layoutMargins.left];
            return cell;
        }
            break;
        default:
            break;
    }
    //  not reached...
    return nil;
}

-(void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    [self resignAllFirstResponder];
    
    switch (indexPath.section) {
        case kVcFormArgs:
        {
            //  表单数据项点击
            switch ([[_rowTypeArray objectAtIndex:indexPath.row] integerValue]) {
                case kVcSubTo:
                {
                    VCSearchNetwork* vc = [[VCSearchNetwork alloc] initWithSearchType:enstAccount callback:^(id account_info) {
                        if (account_info){
                            //  TODO:fowallet
                            NSLog(@"select: %@", account_info);
                            [_transfer_args setObject:account_info forKey:@"to"];
                            [_mainTableView reloadData];
                        }
                    }];
                    [self pushViewController:vc
                                     vctitle:NSLocalizedString(@"kVcTitleSelectToAccount", @"搜索目标帐号")
                                   backtitle:kVcDefaultBackTitleName];
                }
                    break;
                case kVcSubAssetID:
                    [self onSelectAssetClicked];
                    break;
                case kVcSubPreimage_HashMethod:
                case kVcSubHashCode_HashMethod:
                    [self onHashMethodClicked];
                    break;
                case kVcSubPreimage_Expiration:
                case kVcSubHashCode_Expiration:
                    [self onExpirationClicked];
                    break;
                case kVcSubHashCode_PreimageLength:
                    [self onPreimageLengthClicked];
                    break;
                default:
                    break;
            }
        }
            break;
        case kVcSubmitBtn:
        {
            //  表单行为按钮点击
            [[IntervalManager sharedIntervalManager] callBodyWithFixedInterval:tableView body:^{
                [self delay:^{
                    [self gotoCreateHTLC];
                }];
            }];
        }
            break;
        default:
            break;
    }
}

/**
 *  (private) 选择转账资产
 */
- (void)onSelectAssetClicked
{
    id curr_asset = [_transfer_args objectForKey:@"asset"];
    assert(curr_asset);
    id curr_symbol = [curr_asset objectForKey:@"symbol"];

    NSInteger defaultIndex = 0;
    NSInteger idx = 0;
    for (id asset in _asset_list) {
        if ([[asset objectForKey:@"symbol"] isEqualToString:curr_symbol]){
            defaultIndex = idx;
            break;
        }
        ++idx;
    }
    [[[MyPopviewManager sharedMyPopviewManager] showModernListView:self.navigationController
                                                           message:NSLocalizedString(@"kVcTransferTipSelectAsset", @"请选择要转账的资产")
                                                             items:_asset_list
                                                           itemkey:@"symbol"
                                                      defaultIndex:defaultIndex] then:(^id(id result) {
        if (result){
            id select_symbol = [result objectForKey:@"symbol"];
            if (![select_symbol isEqualToString:curr_symbol]){
                [self setAsset:result];
                [_mainTableView reloadData];
            }
        }
        return nil;
    })];
}

/**
 *  (private) 原像长度选择
 */
- (void)onPreimageLengthClicked
{
    //  TODO:2.1 未完成 多语言
    NSInteger defaultIndex = 0;
    NSMutableArray* list = [NSMutableArray array];
    for (NSInteger i = 1; i <= 256; ++i) {
        if (i == _currPreimageLength){
            defaultIndex = [list count];
        }
        [list addObject:@{@"name":[NSString stringWithFormat:@"%@", @(i)], @"value":@(i)}];
    }
    [[[MyPopviewManager sharedMyPopviewManager] showModernListView:self.navigationController
                                                           message:@"请选择原像字符长度"
                                                             items:list
                                                           itemkey:@"name"
                                                      defaultIndex:defaultIndex] then:(^id(id result) {
        if (result){
            NSInteger len = [[result objectForKey:@"value"] integerValue];
            if (_currPreimageLength != len){
                _currPreimageLength = len;
                [_mainTableView reloadData];
            }
        }
        return nil;
    })];
}

/**
 *  (private) 散列算法点击
 */
- (void)onHashMethodClicked
{
    //  TODO:2.1 未完成
    NSInteger defaultIndex = 0;
    NSInteger currValue = [[_currHashType objectForKey:@"value"] integerValue];
    NSInteger idx = 0;
    for (id item in _const_hashtype_list) {
        if ([[item objectForKey:@"value"] integerValue] == currValue){
            defaultIndex = idx;
            break;
        }
        ++idx;
    }
    [[[MyPopviewManager sharedMyPopviewManager] showModernListView:self.navigationController
                                                           message:@"请选择哈希算法"
                                                             items:_const_hashtype_list
                                                           itemkey:@"name"
                                                      defaultIndex:defaultIndex] then:(^id(id result) {
        if (result){
            NSInteger type = [[result objectForKey:@"value"] integerValue];
            if ([[_currHashType objectForKey:@"value"] integerValue] != type){
                _currHashType = result;
                [_mainTableView reloadData];
            }
        }
        return nil;
    })];
}

/**
 *  (private) 合约有效期点击
 */
- (void)onExpirationClicked
{
    //  TODO:2.1 未完成
    NSInteger defaultIndex = 0;
    NSInteger currValue = [[_currExpire objectForKey:@"value"] integerValue];
    NSInteger idx = 0;
    for (id item in _const_expire_list) {
        if ([[item objectForKey:@"value"] integerValue] == currValue){
            defaultIndex = idx;
            break;
        }
        ++idx;
    }
    [[[MyPopviewManager sharedMyPopviewManager] showModernListView:self.navigationController
                                                           message:@"请选择合约有效期"
                                                             items:_const_expire_list
                                                           itemkey:@"name"
                                                      defaultIndex:defaultIndex] then:(^id(id result) {
        if (result){
            NSInteger sec = [[result objectForKey:@"value"] integerValue];
            if ([[_currExpire objectForKey:@"value"] integerValue] != sec){
                _currExpire = result;
                [_mainTableView reloadData];
            }
        }
        return nil;
    })];
}

@end