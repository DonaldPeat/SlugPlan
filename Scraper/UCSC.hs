module Scraper.UCSC where

import Prelude
import System.IO
import Pdf.Toolbox.Document
import Data.Maybe    (catMaybes)
import Data.Char     (toUpper)
import Data.List     (sort, group)
import Control.Monad (void)
import Data.Text     (unpack)

import Text.Parsec         ((<|>))
import Control.Applicative ((<*), (<$>))
import Control.Monad       (when)

import qualified Text.Parsec     as Parsec
import qualified Data.Map.Strict as Map

import Scraper.Subjects

type SubjectMap   = Map.Map Subject [(String, String, [String])]
type UCSCParser a = Parsec.Parsec String () a

getSubjectMap :: FilePath -> IO SubjectMap
getSubjectMap filename = do
    input <- readFile filename
    let classes = getSubjectMap' input filename
    case classes of
        (Just cs) -> return cs
        _         -> return Map.empty

getSubjectMap' :: String -> String -> Maybe SubjectMap
getSubjectMap' input filename =
    let classes = Parsec.parse getAllSubjectCourses filename input
    in case classes of
        (Right cs) -> Just cs
        _          -> Nothing

getAllSubjectCourses :: UCSCParser SubjectMap
getAllSubjectCourses = Map.fromList <$> (Parsec.many $ Parsec.try getNextSubjectCourses)

getNextSubjectCourses :: UCSCParser (Subject, [(String, String, [String])])
getNextSubjectCourses = (Parsec.try $ do
    subject <- subjectBegin
    courses <- Parsec.manyTill (getCourse subject) (Parsec.try subjectEnd)
    return (subject, courses)
    ) <|> (Parsec.anyChar >> getNextSubjectCourses)

anySubjectHeader :: UCSCParser String
anySubjectHeader = Parsec.try $ createMultiParser $
    map ((map toUpper) . subjectName) [AcadEnglish ..]

subjectBegin :: UCSCParser Subject
subjectBegin = do
    header <- anySubjectHeader
    Parsec.spaces
    Parsec.optional $ Parsec.string "PROGRAM"
    Parsec.spaces
    Parsec.optional $ Parsec.string "COURSES"
    Parsec.spaces
    courseHeader
    return $ fst $ head $ filter (\(_, s) -> s == header) subjects
    where subjects = map (\s -> (s, map toUpper $ subjectName s)) [AcadEnglish ..]

subjectEnd :: UCSCParser ()
subjectEnd = do
    Parsec.spaces
    void $ Parsec.string "* Not offered"
            <|> Parsec.try revisedString
            <|> Parsec.lookAhead anySubjectHeader

revisedString :: UCSCParser String
revisedString = do
    Parsec.string "Revised"
    Parsec.optional $ Parsec.char ':'
    Parsec.char ' '
    Parsec.count 2 Parsec.digit
    Parsec.char '/'
    Parsec.count 2 Parsec.digit
    Parsec.char '/'
    (Parsec.try $ Parsec.count 4 Parsec.digit) <|> Parsec.count 2 Parsec.digit

subjectHeader :: Subject -> UCSCParser String
subjectHeader = Parsec.string . (map toUpper) . subjectName

createMultiParser :: [String] -> UCSCParser String
createMultiParser [] = return ""
createMultiParser strns
    | flen /= slen        = Parsec.option "" $ Parsec.try choices
    | length prefixes > 1 = choices
    | otherwise           = subPar $ head prefixes
    where filtered = sort $ filter (not . null) strns
          prefixes = map head $ group $ map head filtered
          flen     = length filtered
          slen     = length strns
          choices  = Parsec.choice $ map subPar prefixes
          subPar c = do
            Parsec.char c
            out <- createMultiParser $ map tail $ filter ((==) c . head) filtered
            return $ c : out

courseHeader :: UCSCParser String
courseHeader = do
    (Parsec.char 'L' >> (Parsec.string "OWER-DIVISION COURSES"
                     <|> Parsec.string "ower-Division Courses"))
        <|> (Parsec.char 'U' >> ((Parsec.string "PPER"
                                  >> Parsec.oneOf " -"
                                  >> Parsec.string "DIVISION COURSES")
                             <|> Parsec.string "pper-Division Courses"))
        <|> (Parsec.char 'G' >> (Parsec.string "RADUATE COURSES"
                             <|> Parsec.string "raduate Courses"))

uniqueSubjectParser :: Subject -> (Bool, UCSCParser String)
uniqueSubjectParser HistoryArt = (True, Parsec.choice
    [ Parsec.string "Europe and the Americas"
    , Parsec.string "Modern Art and Visual Culture in \nEurope and the Americas"
    , Parsec.string "Renaissance"
    , Parsec.string "Oceania and its Diaspora"
    , Parsec.string "Cross-Regional Studies"
    ])
uniqueSubjectParser subject    = (False, return "")

getCourse :: Subject -> UCSCParser (String, String, [String])
getCourse sub = do
    courseBegin
    num     <- getCourseNum
    name    <- getCourseName
    prereqs <- coursePrereqs sub
    courseEnd

    Parsec.optional $ Parsec.try $ newPage sub

    let (unique, parser) = uniqueSubjectParser sub
    when unique $ Parsec.optional $ Parsec.try parser

    return (num, removeNewlines name, removeNewlines <$> prereqs)

courseBegin :: UCSCParser ()
courseBegin = do
    Parsec.spaces
    Parsec.optional $ Parsec.try courseHeader
    Parsec.spaces

courseEnd :: UCSCParser ()
courseEnd = do
    Parsec.space
    Parsec.spaces
    Parsec.try profName
        <|> (Parsec.string "The" >> Parsec.spaces >> Parsec.string "Staff")
    Parsec.optional $ Parsec.char ',' >> courseEnd
    Parsec.spaces

newPage :: Subject -> UCSCParser ()
newPage subject = do
    Parsec.optional $ Parsec.many Parsec.digit >> newline'
    Parsec.string $ subjectSection subject
    spaces
    newline'

getCourseNum :: UCSCParser String
getCourseNum = do
    num <- Parsec.many1 Parsec.digit
    sub <- Parsec.many  Parsec.letter
    Parsec.char '.'
    return $ num ++ sub

getCourseName :: UCSCParser String
getCourseName =
    Parsec.many1 (Parsec.alphaNum <|> Parsec.oneOf " ,?!\"&():+-/'\n\8211") <* periodBreak

coursePrereqs :: Subject -> UCSCParser [String]
coursePrereqs sub = Parsec.try (getPrereqs sub)
    <|> (Parsec.try (Parsec.lookAhead courseEnd) >> return [])
    <|> (Parsec.anyChar >> coursePrereqs sub)

getPrereqs :: Subject -> UCSCParser [String]
getPrereqs sub = do
    Parsec.string "Prerequisite(s): "
    prereqs <- Parsec.manyTill (prereqParser sub) $ Parsec.try
                                                  $ Parsec.lookAhead courseEnd
    return $ prereqs

prereqParser :: Subject -> UCSCParser String
prereqParser _ =
    Parsec.manyTill Parsec.anyChar
        $ (Parsec.try $ Parsec.lookAhead courseEnd)
          <|> (Parsec.try $ Parsec.oneOf ",;." >> return ())

periodBreak :: UCSCParser ()
periodBreak = Parsec.char '.' >> spaces

data PrereqStruct = AndPrereq [PrereqStruct]
                  | OrPrereq  [PrereqStruct]
                  | String

profName :: UCSCParser String
profName = do
    Parsec.notFollowedBy $ Parsec.choice $ map Parsec.string $
        [ "I. Readings"
        , "A. The"
        ]
    initial <- Parsec.upper
    Parsec.char '.'
    Parsec.many1 Parsec.space
    first  <- Parsec.upper
    second <- Parsec.lower
    tail   <- Parsec.manyTill Parsec.lower $ Parsec.lookAhead $ Parsec.oneOf " -,\n"
    extra  <- Parsec.option "" $ Parsec.try $ do
        Parsec.oneOf " -"
        Parsec.optional newline'
        Parsec.notFollowedBy $ Parsec.string "Revised"
        first'  <- Parsec.upper
        second' <- Parsec.lower
        tail'   <- Parsec.manyTill Parsec.lower $ Parsec.lookAhead $ Parsec.oneOf " ,\n"
        return (' ':first':second':tail')
    endName
    return $ (initial : ". ") ++ (first:second:tail) ++ extra
    where endName = (Parsec.char ',' >> void courseEnd) <|> (spaces >> newline')

newline' :: UCSCParser ()
newline' = void $ Parsec.newline

spaces :: UCSCParser ()
spaces = void $ Parsec.many $ Parsec.char ' '

removeNewlines :: String -> String
removeNewlines = filter ((/=) '\n')

parsePdf :: FilePath -> IO String
parsePdf filename =
    withBinaryFile filename ReadMode $ \handle -> do
        res <- runPdfWithHandle handle knownFilters $ do
            pdf      <- document
            catalog  <- documentCatalog pdf
            rootNode <- catalogPageNode catalog
            kids     <- pageNodeKids rootNode
            count    <- pageNodeNKids rootNode

            concat <$> mapM (getPageText rootNode) [3..(count - 1)]
            --mapM_ printKid kids
            --page <- pageNodePageByNum rootNode 2
            --printPage page
        case res of
            (Left err)   -> print err >> return ""
            (Right strn) -> return strn

printKid :: (MonadPdf m, MonadIO m) => Ref -> PdfE m ()
printKid kid = do
    pageNode <- loadPageNode kid
    case pageNode of
        (PageTreeNode node) -> do
            kids <- pageNodeKids node
            count <- pageNodeNKids node
            liftIO $ print $ "Node with " ++ show count ++ " children"
            mapM_ printKid kids
        (PageTreeLeaf leaf) -> do
            text <- pageExtractText leaf
            liftIO $ print text

getPageText :: (MonadPdf m, MonadIO m) => PageNode -> Int -> PdfE m String
getPageText node n = do
    page <- pageNodePageByNum node n
    text <- pageExtractText page
    return $ unpack text
