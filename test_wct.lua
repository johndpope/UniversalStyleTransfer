require 'torch'
require 'nn'
require 'image'
require 'paths'
require 'lib/NonparametricPatchAutoencoderFactory'
require 'lib/MaxCoord'
require 'lib/utils'
require 'nngraph'
require 'cudnn'
require 'cunn'

local cmd = torch.CmdLine()

cmd:option('-style', 'input/style/018.jpg', 'path to the style image')
cmd:option('-styleDir', '', 'path to the style image folder')
cmd:option('-content', 'input/content/006.jpg', 'path to the content image')
cmd:option('-contentDir', '', 'path to the content image folder')

cmd:option('-swap5', 0)
cmd:option('-alpha', 0.6)
cmd:option('-patchSize', 3)
cmd:option('-patchStride', 1)
cmd:option('-synthesis', 0 , '0-transfer, 1-synthesis')

cmd:option('-vgg1', 'models/vgg_normalised_conv1_1.t7', 'Path to the VGG conv1_1')
cmd:option('-vgg2', 'models/vgg_normalised_conv2_1.t7', 'Path to the VGG conv2_1')
cmd:option('-vgg3', 'models/vgg_normalised_conv3_1.t7', 'Path to the VGG conv3_1')
cmd:option('-vgg4', 'models/vgg_normalised_conv4_1.t7', 'Path to the VGG conv4_1')
cmd:option('-vgg5', 'models/vgg_normalised_conv5_1.t7', 'Path to the VGG conv5_1')

cmd:option('-decoder5', 'models/feature_invertor_conv5_1.t7', 'Path to the decoder5')
cmd:option('-decoder4', 'models/feature_invertor_conv4_1.t7', 'Path to the decoder4')
cmd:option('-decoder3', 'models/feature_invertor_conv3_1.t7', 'Path to the decoder3')
cmd:option('-decoder2', 'models/feature_invertor_conv2_1.t7', 'Path to the decoder2')
cmd:option('-decoder1', 'models/feature_invertor_conv1_1.t7', 'Path to the decoder1')

cmd:option('-contentSize', 768, 'New (minimum) size for the content image, keeping the original size if set to 0')
cmd:option('-styleSize', 768, 'New (minimum) size for the style image, keeping the original size if set to 0')
cmd:option('-crop', false, 'If true, center crop both content and style image before resizing')
cmd:option('-saveExt', 'jpg', 'The extension name of the output image')
cmd:option('-gpu', 0, 'Zero-indexed ID of the GPU to use; for CPU mode set -gpu = -1')
cmd:option('-outputDir', 'output', 'Directory to save the output image(s)')


opt = cmd:parse(arg)

assert(opt.content ~= '' or opt.contentDir ~= '', 'Either --content or --contentDir should be given.')
assert(opt.style ~= '' or opt.styleDir ~= '', 'Either --style or --styleDir should be given.')
assert(opt.content == '' or opt.contentDir == '', '--content and --contentDir cannot both be given.')
assert(opt.style == '' or opt.styleDir == '', '--style and --styleDir cannot both be given.')

function maximum(a,b)
    if a<b then
        return b
    else
        return a
    end
end

function loadModel()
    vgg1 = torch.load(opt.vgg1)
    vgg2 = torch.load(opt.vgg2)
    vgg3 = torch.load(opt.vgg3)
    vgg4 = torch.load(opt.vgg4)
    vgg5 = torch.load(opt.vgg5)

    decoder5 = torch.load(opt.decoder5)
    decoder4 = torch.load(opt.decoder4)
    decoder3 = torch.load(opt.decoder3)
    decoder2 = torch.load(opt.decoder2)
    decoder1 = torch.load(opt.decoder1)

    if opt.gpu >= 0 then
        print('GPU mode')
        vgg1:cuda()
        vgg2:cuda()
        vgg3:cuda()
        vgg4:cuda()
        vgg5:cuda()
        decoder1:cuda()
        decoder2:cuda()
        decoder3:cuda()
        decoder4:cuda()
        decoder5:cuda()
    else
        print('CPU mode')
        vgg1:float()
        vgg2:float()
        vgg3:float()
        vgg4:float()
        vgg5:float()
        decoder1:float()
        decoder2:float()
        decoder3:float()
        decoder4:float()
        decoder5:float()
    end
end


function feature_swap_whiten(cF, sF)
   
   local contentFeature = cF
   local styleFeature = sF

   contentFeature = contentFeature:double()
   styleFeature = styleFeature:double()

   -- content feature whitening
    local sg = contentFeature:size()
    local contentFeature1 = contentFeature:view(sg[1], sg[2]*sg[3])
    local c_mean = torch.mean(contentFeature1, 2)
    contentFeature1 = contentFeature1 - c_mean:expandAs(contentFeature1)
    local contentCov = torch.mm(contentFeature1, contentFeature1:t()):div(sg[2]*sg[3]-1)  --512*512
    local c_e, c_v = torch.symeig(contentCov, 'V')  

    local k_c = 0
    for i=1, sg[1] do
       if c_e[i] > 0.00001 then
            k_c = i
            break
       end
    end

    -- style feature whitening
    local sz = styleFeature:size()
    local styleFeature1 = styleFeature:view(sz[1], sz[2]*sz[3])
    local s_mean = torch.mean(styleFeature1, 2)
    styleFeature1 = styleFeature1 - s_mean:expandAs(styleFeature1)
    local styleCov = torch.mm(styleFeature1, styleFeature1:t()):div(sz[2]*sz[3]-1)  --512*512
    local s_e, s_v = torch.symeig(styleCov, 'V')

    local k_s = 0
    for i=1, sz[1] do
       if s_e[i] > 0.00001 then
            k_s = i
            break
       end
    end

    local k = maximum(k_c, k_s)
    local s_d = torch.sqrt(s_e[{{k,sz[1]}}]):pow(-1)
    local whiten_styleFeature = s_v[{{},{k,sz[1]}}]*torch.diag(s_d)*(s_v[{{},{k,sz[1]}}]:t())*styleFeature1
    

    local swap_enc, swap_dec = NonparametricPatchAutoencoderFactory.buildAutoencoder(whiten_styleFeature:resize(sz[1], sz[2], sz[3]), opt.patchSize, opt.patchStride, false, false, true)

    local swap = nn.Sequential()
    swap:add(swap_enc)
    swap:add(nn.MaxCoord())
    swap:add(swap_dec)
    swap:evaluate()

    local c_d = torch.sqrt(c_e[{{k,sg[1]}}]):pow(-1)

    local whiten_contentFeature = c_v[{{},{k,sg[1]}}]*torch.diag(c_d)*(c_v[{{},{k,sg[1]}}]:t())*contentFeature1
       
    local swap_latent = swap:forward(whiten_contentFeature:resize(sg[1], sg[2], sg[3])):clone()
    local swap_latent1 = swap_latent:view(sg[1], sg[2]*sg[3])

    local s_d1 = torch.sqrt(s_e[{{k,sz[1]}}])

    local targetFeature = s_v[{{},{k,sz[1]}}]*(torch.diag(s_d1))*(s_v[{{},{k,sz[1]}}]:t())*swap_latent1

    targetFeature = targetFeature + s_mean:expandAs(targetFeature)

    local tFeature = targetFeature:resize(sg[1], sg[2], sg[3])

    if opt.gpu >= 0 then
       return tFeature:cuda()
    else
       return tFeature:float()
    end
end


function feature_wct(cF, sF)
   
   local contentFeature = cF
   local styleFeature = sF
  
   contentFeature = contentFeature:double()
   styleFeature = styleFeature:double()
 
   -- content feature whitening
    local sg = contentFeature:size()
    local contentFeature1 = contentFeature:view(sg[1], sg[2]*sg[3])
    local c_mean = torch.mean(contentFeature1, 2)
    contentFeature1 = contentFeature1 - c_mean:expandAs(contentFeature1)
    local contentCov = torch.mm(contentFeature1, contentFeature1:t()):div(sg[2]*sg[3]-1)  --512*512
    local c_e, c_v = torch.symeig(contentCov, 'V')  

    local k_c = 0
    for i=1, sg[1] do
       if c_e[i] > 0.00001 then
            k_c = i
            break
       end
    end

    -- style feature whitening
    local sz = styleFeature:size()
    local styleFeature1 = styleFeature:view(sz[1], sz[2]*sz[3])
    local s_mean = torch.mean(styleFeature1, 2)
    styleFeature1 = styleFeature1 - s_mean:expandAs(styleFeature1)
    local styleCov = torch.mm(styleFeature1, styleFeature1:t()):div(sz[2]*sz[3]-1)  --512*512
    local s_e, s_v = torch.symeig(styleCov, 'V')

    local k_s = 0
    for i=1, sz[1] do
       if s_e[i] > 0.00001 then
            k_s = i
            break
       end
    end

    local k = maximum(k_c, k_s)

   
    local c_d = c_e[{{k,sg[1]}}]:sqrt():pow(-1)

    local whiten_contentFeature = c_v[{{},{k,sg[1]}}]*torch.diag(c_d)*(c_v[{{},{k,sg[1]}}]:t())*contentFeature1
       
    local s_d1 = s_e[{{k,sz[1]}}]:sqrt()

    local targetFeature = s_v[{{},{k,sz[1]}}]*(torch.diag(s_d1))*(s_v[{{},{k,sz[1]}}]:t())*whiten_contentFeature

    targetFeature = targetFeature + s_mean:expandAs(targetFeature)
    local tFeature = targetFeature:resize(sg[1], sg[2], sg[3])

    if opt.gpu >= 0 then
       return tFeature:cuda()
    else
       return tFeature:float()
    end
end


local function styleTransfer(content, style, iteration)

    --We delete the model after using it to save momery for performing transfer on large image size
    --So we need to reload it each time for a new round of transfer
    loadModel()

    if opt.gpu >= 0 then
        content = content:cuda()
        if opt.synthesis == 1 and iteration == 1 then
           local gg = content:size()
           content = torch.zeros(gg[1],gg[2],gg[3]):uniform():cuda()
           print('input noise for synthesis')
        end
        style = style:cuda()
    else
        content = content:float()
        if opt.synthesis == 1 and iteration == 1 then
           local gg = content:size()
           content = torch.zeros(gg[1],gg[2],gg[3]):uniform():float()
           print('input noise for synthesis')
        end
        style = style:float()
    end


    --WCT on conv5_1
    -------------------------------------------------------------------------- 
    --Note that since conv5 feature is hard to invert to preserve the content,
    --if you want to better preserve the content, you can start from WCT on 
    --conv4_1 first, i.e., on Line 287,
    --local cF4 = vgg4:forward(content):clone()
    --------------------------------------------------------------------------
    local cF5 = vgg5:forward(content):clone()
    local sF5 = vgg5:forward(style):clone()
    vgg5 = nil

    local csF5 = nil
    if opt.swap5 ~= 0 then   
        csF5 = feature_swap_whiten(cF5, sF5)
    else   
        csF5 = feature_wct(cF5, sF5)
    end

    csF5 = opt.alpha * csF5 + (1.0-opt.alpha) * cF5
    local Im5 = decoder5:forward(csF5)
    decoder5 = nil

    --WCT on conv4_1
    local cF4 = vgg4:forward(Im5):clone()
    local sF4 = vgg4:forward(style):clone()
    vgg4 = nil

    local csF4 = feature_swap_whiten(cF4, sF4)
    csF4 = opt.alpha * csF4 + (1.0-opt.alpha) * cF4
    local Im4 = decoder4:forward(csF4)
    decoder4 = nil

    --WCT on conv3_1
    local cF3 = vgg3:forward(Im4):clone()
    local sF3 = vgg3:forward(style):clone()
    vgg3 = nil

    local csF3 = feature_wct(cF3, sF3)
    csF3 = opt.alpha * csF3 + (1.0-opt.alpha) * cF3 

    local Im3 = decoder3:forward(csF3)
    decoder3 = nil

    --WCT on conv2_1
    local cF2 = vgg2:forward(Im3):clone()
    local sF2 = vgg2:forward(style):clone()
    vgg2 = nil

    local csF2 = feature_wct(cF2, sF2)
    csF2 = opt.alpha * csF2 + (1.0-opt.alpha) * cF2

    local Im2 = decoder2:forward(csF2)
    decoder2 = nil

    --WCT on conv1_1
    local cF1 = vgg1:forward(Im2):clone()
    local sF1 = vgg1:forward(style):clone()
    vgg1 = nil

    local csF1 = feature_wct(cF1, sF1)
    csF1 = opt.alpha * csF1 + (1.0-opt.alpha) * cF1

    local Im1 = decoder1:forward(csF1) 
    decoder1 = nil

    return Im1
end

print('Creating save folder at ' .. opt.outputDir)
paths.mkdir(opt.outputDir)

local contentPaths = {}
local stylePaths = {}

if opt.content ~= '' then -- use a single content image
    table.insert(contentPaths, opt.content)
else -- use a batch of content images
    assert(opt.contentDir ~= '', "Either opt.contentDir or opt.content should be non-empty!")
    contentPaths = extractImageNamesRecursive(opt.contentDir)
end

if opt.style ~= '' then 
    style_image_list = opt.style:split(',')
    if #style_image_list == 1 then
        style_image_list = style_image_list[1]
    end
    table.insert(stylePaths, style_image_list)
else -- use a batch of style images
    assert(opt.styleDir ~= '', "Either opt.styleDir or opt.style should be non-empty!")
    stylePaths = extractImageNamesRecursive(opt.styleDir)
end

local numContent = #contentPaths
local numStyle = #stylePaths
print("# Content images: " .. numContent)
print("# Style images: " .. numStyle)


for i=1,numContent do
    local contentPath = contentPaths[i]
    local contentExt = paths.extname(contentPath)
    local contentImg = image.load(contentPath, 3, 'float')
    local contentName = paths.basename(contentPath, contentExt)
    local contentImg = sizePreprocess(contentImg, opt.contentSize)

    for j=1,numStyle do

        local stylePath = stylePaths[j]
  
        styleExt = paths.extname(stylePath)
        styleImg = image.load(stylePath, 3, 'float')
        styleImg = sizePreprocess(styleImg, opt.styleSize)
        styleName = paths.basename(stylePath, styleExt)

        if opt.synthesis == 0 then
            local timer = torch.Timer() 
            local output = styleTransfer(contentImg, styleImg, 1)
            print('Time: ' .. timer:time().real .. ' seconds')
            local savePath = paths.concat(opt.outputDir, contentName .. '_stylized_by_' .. styleName .. '_alpha_' ..opt.alpha*100 .. '.' .. opt.saveExt)
            print('Output image saved at: ' .. savePath)
            image.save(savePath, output)

       else
            --We empirically find that 3 iterations are enough for a visually-pleasing result
            for iter = 1, 3 do
                local timer = torch.Timer() 
                output = styleTransfer(contentImg, styleImg, iter)
                print('Time: ' .. timer:time().real .. ' seconds')
                local savePath = paths.concat(opt.outputDir, styleName .. '_iter' .. iter .. '_alpha_' ..opt.alpha*100 .. '.' .. opt.saveExt)
                print('Output image saved at: ' .. savePath)
                image.save(savePath, output)
                contentImg = output
            end
       end

    end
end
